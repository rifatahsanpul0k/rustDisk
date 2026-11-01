use crate::cancel::ScanToken;
use crate::scanner::calculate_dir_footprint_cancellable;
use crate::{DuplicateGroup, DuplicateKind, DuplicateMember};
use blake3::Hasher;
use jwalk::WalkDir;
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const BYTES_PER_BLOCK: u64 = 512;
const DEFAULT_MIN_SIZE_BYTES: u64 = 1024 * 1024;
const EDGE_BYTES: usize = 4096;
const DAY_SECONDS: u64 = 86_400;

const BUNDLE_SUFFIXES: [&str; 7] = [
    ".app",
    ".framework",
    ".photoslibrary",
    ".xcodeproj",
    ".xcworkspace",
    ".playground",
    ".tvlibrary",
];

const SKIP_DIRECTORY_NAMES: [&str; 10] = [
    ".git",
    ".Trash",
    "node_modules",
    ".venv",
    "venv",
    "target",
    ".gradle",
    ".next",
    "Library",
    "System",
];

#[derive(Clone, Debug)]
struct FileCandidate {
    path: PathBuf,
    physical_bytes: u64,
    logical_bytes: u64,
    modified: SystemTime,
    device: u64,
    inode: u64,
}

#[derive(Clone, Debug)]
struct PackageEntry {
    path: PathBuf,
    name: String,
    source_label: String,
    physical_bytes: u64,
    logical_bytes: u64,
    modified: SystemTime,
    group_key: String,
    version_key: String,
}

fn canonical_path(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn days_since_modified(modified: SystemTime) -> u64 {
    SystemTime::now()
        .duration_since(modified)
        .unwrap_or(Duration::ZERO)
        .as_secs()
        / DAY_SECONDS
}

fn metadata_modified(path: &Path) -> SystemTime {
    fs::symlink_metadata(path)
        .and_then(|metadata| metadata.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH)
}

fn is_bundle(path: &Path) -> bool {
    let name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    BUNDLE_SUFFIXES.iter().any(|suffix| name.ends_with(suffix))
}

fn is_protected_path(path: &Path) -> bool {
    path.starts_with("/System")
        || path.starts_with("/bin")
        || path.starts_with("/sbin")
        || path.starts_with("/usr/bin")
        || path.components().any(|component| {
            let name = component.as_os_str().to_string_lossy();
            SKIP_DIRECTORY_NAMES.contains(&name.as_ref())
        })
}

fn should_skip_directory(path: &Path) -> bool {
    is_protected_path(path) || is_bundle(path)
}

fn candidate_from_path(path: &Path, min_size_bytes: u64) -> Option<FileCandidate> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if !metadata.file_type().is_file() {
        return None;
    }

    let physical_bytes = metadata.blocks().saturating_mul(BYTES_PER_BLOCK);
    if physical_bytes < min_size_bytes {
        return None;
    }

    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    Some(FileCandidate {
        path: path.to_path_buf(),
        physical_bytes,
        logical_bytes: metadata.len(),
        modified,
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

fn walk_files(root: &Path, min_size_bytes: u64, token: &ScanToken) -> Vec<FileCandidate> {
    if !root.exists() || should_skip_directory(root) {
        return Vec::new();
    }

    let walk_token = token.clone();
    let walker = WalkDir::new(root)
        .skip_hidden(false)
        .follow_links(false)
        .process_read_dir(move |_, _, _, children| {
            if walk_token.is_cancelled() {
                children.clear();
                return;
            }
            for child in children.iter_mut() {
                if let Ok(entry) = child {
                    let path = entry.path();
                    if entry.file_type().is_dir() && should_skip_directory(&path) {
                        entry.read_children_path = None;
                    }
                }
            }
        });

    let mut candidates = Vec::new();
    let mut seen_inodes = HashSet::new();

    for entry in walker.into_iter().flatten() {
        if token.is_cancelled() {
            return Vec::new();
        }
        let path = entry.path();
        if !entry.file_type().is_file() || is_protected_path(&path) {
            continue;
        }

        let Some(candidate) = candidate_from_path(&path, min_size_bytes) else {
            continue;
        };

        // A hardlink has one inode and one physical allocation. Keep only its
        // first path so it cannot be presented as reclaimable duplicate space.
        if !seen_inodes.insert((candidate.device, candidate.inode)) {
            continue;
        }
        candidates.push(candidate);
    }

    candidates
}

fn edge_hash(candidate: &FileCandidate) -> Option<String> {
    let mut file = File::open(&candidate.path).ok()?;
    let mut first = vec![0u8; EDGE_BYTES.min(candidate.logical_bytes as usize)];
    file.read_exact(&mut first).ok()?;

    let last_len = EDGE_BYTES.min(candidate.logical_bytes as usize);
    let mut last = vec![0u8; last_len];
    file.seek(SeekFrom::Start(
        candidate.logical_bytes.saturating_sub(last_len as u64),
    ))
    .ok()?;
    file.read_exact(&mut last).ok()?;

    let mut hasher = Hasher::new();
    hasher.update(&first);
    hasher.update(&last);
    hasher.update(&candidate.logical_bytes.to_le_bytes());
    Some(hasher.finalize().to_hex().to_string())
}

/// Hashes a whole file in 64 KiB chunks. Returns `None` on read errors and as
/// soon as `token` is cancelled, so a multi-gigabyte file stops mid-read.
fn full_hash(path: &Path, token: &ScanToken) -> Option<String> {
    let mut file = File::open(path).ok()?;
    let mut hasher = Hasher::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        if token.is_cancelled() {
            return None;
        }
        let read = file.read(&mut buffer).ok()?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Some(hasher.finalize().to_hex().to_string())
}

fn edge_collision_candidates(candidates: &[FileCandidate], token: &ScanToken) -> HashSet<PathBuf> {
    let mut by_size: HashMap<u64, Vec<FileCandidate>> = HashMap::new();
    for candidate in candidates {
        by_size
            .entry(candidate.logical_bytes)
            .or_default()
            .push(candidate.clone());
    }

    let edge_candidates: Vec<(FileCandidate, String)> = by_size
        .into_par_iter()
        .filter(|(_, files)| files.len() >= 2)
        .flat_map(|(_, files)| {
            files
                .into_par_iter()
                .filter_map(|candidate| {
                    if token.is_cancelled() {
                        return None;
                    }
                    edge_hash(&candidate).map(|hash| (candidate, hash))
                })
                .collect::<Vec<_>>()
        })
        .collect();

    let mut by_edge: HashMap<String, Vec<(FileCandidate, String)>> = HashMap::new();
    for (candidate, edge) in edge_candidates {
        by_edge
            .entry(edge.clone())
            .or_default()
            .push((candidate, edge));
    }

    by_edge
        .into_iter()
        .filter(|(_, files)| files.len() >= 2)
        .flat_map(|(_, files)| files.into_iter().map(|(candidate, _)| candidate.path))
        .collect()
}

fn full_hashes(paths: HashSet<PathBuf>, token: &ScanToken) -> HashMap<PathBuf, String> {
    paths
        .into_par_iter()
        .filter_map(|path| full_hash(&path, token).map(|hash| (path, hash)))
        .collect()
}

fn normalized_path(path: &Path) -> String {
    canonical_path(path).to_string_lossy().into_owned()
}

fn source_label(path: &Path) -> String {
    let path_string = path.to_string_lossy();
    if path_string.contains("/Downloads/") {
        "Downloads Copy".to_owned()
    } else if path_string.contains("/Homebrew/") || path_string.contains("/Cellar/") {
        "Homebrew".to_owned()
    } else if path_string.contains("/.pyenv/") {
        "pyenv".to_owned()
    } else if path_string.contains("/.nvm/") {
        "nvm".to_owned()
    } else if path_string.contains("fnm/node-versions") {
        "fnm".to_owned()
    } else {
        "Primary Folder".to_owned()
    }
}

fn duplicate_category(path: &Path) -> &'static str {
    let extension = path
        .extension()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    if matches!(
        extension.as_str(),
        "dmg"
            | "iso"
            | "pkg"
            | "mpkg"
            | "xip"
            | "ipsw"
            | "zip"
            | "tar"
            | "gz"
            | "tgz"
            | "bz2"
            | "xz"
            | "zst"
            | "7z"
            | "rar"
            | "bak"
    ) {
        "Archives & Installers"
    } else if matches!(
        extension.as_str(),
        "safetensors"
            | "gguf"
            | "pt"
            | "pth"
            | "onnx"
            | "ckpt"
            | "pb"
            | "tflite"
            | "mlmodel"
            | "h5"
            | "hdf5"
            | "parquet"
            | "arrow"
            | "feather"
            | "jsonl"
            | "csv"
            | "sqlite"
            | "db"
    ) {
        "AI Models & Datasets"
    } else {
        "Media & Documents"
    }
}

fn noisy_path(path: &Path) -> bool {
    path.components().any(|component| {
        matches!(
            component
                .as_os_str()
                .to_string_lossy()
                .to_ascii_lowercase()
                .as_str(),
            "copy" | "backup" | "old" | "tmp"
        )
    })
}

fn noisy_name(path: &Path) -> bool {
    let name = path
        .file_stem()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    name.ends_with(" copy")
        || name.ends_with("-1")
        || name.ends_with(" (1)")
        || name.contains(" backup")
}

fn keep_score(member: &FileCandidate) -> (u8, u8, u8, SystemTime, String) {
    (
        u8::from(member.path.to_string_lossy().contains("/Downloads/")),
        u8::from(noisy_path(&member.path)),
        u8::from(noisy_name(&member.path)),
        member.modified,
        normalized_path(&member.path),
    )
}

fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut index = 0usize;
    while value >= 1000.0 && index < UNITS.len() - 1 {
        value /= 1000.0;
        index += 1;
    }
    if index == 0 {
        format!("{} {}", bytes, UNITS[index])
    } else {
        format!("{value:.1} {}", UNITS[index])
    }
}

fn duplicate_member(
    path: &Path,
    physical_bytes: u64,
    logical_bytes: u64,
    modified: SystemTime,
    is_keep_recommended: bool,
    source: String,
) -> DuplicateMember {
    let canonical = canonical_path(path);
    DuplicateMember {
        id: canonical.to_string_lossy().into_owned(),
        name: path
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string_lossy().into_owned()),
        path: canonical.to_string_lossy().into_owned(),
        physical_bytes,
        logical_bytes,
        days_since_modified: days_since_modified(modified),
        is_keep_recommended,
        source_label: source,
    }
}

fn make_file_group(hash: &str, mut files: Vec<FileCandidate>) -> DuplicateGroup {
    files.sort_by_key(keep_score);
    let keep_path = files[0].path.clone();
    let members = files
        .iter()
        .map(|file| {
            duplicate_member(
                &file.path,
                file.physical_bytes,
                file.logical_bytes,
                file.modified,
                file.path == keep_path,
                source_label(&file.path),
            )
        })
        .collect::<Vec<_>>();
    let reclaimable = members
        .iter()
        .filter(|member| !member.is_keep_recommended)
        .map(|member| member.physical_bytes)
        .sum();
    let title = files
        .first()
        .and_then(|file| file.path.file_name())
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Identical files".to_owned());

    DuplicateGroup {
        id: format!("file:{hash}"),
        title,
        subtitle: format!(
            "{} identical copies · Keep 1, reclaim {}",
            members.len(),
            human_bytes(reclaimable)
        ),
        kind: DuplicateKind::DuplicateFile,
        category: duplicate_category(&files[0].path).to_owned(),
        single_item_bytes: members[0].physical_bytes,
        reclaimable_physical_bytes: reclaimable,
        members,
    }
}

#[derive(Clone, Debug)]
struct DirectoryFile {
    relative_name: String,
    hash: String,
    physical_bytes: u64,
    logical_bytes: u64,
}

#[derive(Clone, Debug)]
struct DirectorySignature {
    path: PathBuf,
    files: Vec<DirectoryFile>,
    physical_bytes: u64,
    logical_bytes: u64,
    modified: SystemTime,
}

fn directory_shape_key(path: &Path, files: &[FileCandidate]) -> String {
    let mut entries = files
        .iter()
        .filter_map(|file| {
            let relative_name = file.path.strip_prefix(path).ok()?.to_string_lossy();
            Some(format!("{relative_name}\0{}", file.logical_bytes))
        })
        .collect::<Vec<_>>();
    entries.sort();
    entries.join("\0")
}

fn directory_signature(
    path: &Path,
    files: &[FileCandidate],
    hashes: &HashMap<PathBuf, String>,
) -> Option<DirectorySignature> {
    let mut directory_files = Vec::new();
    for file in files {
        let hash = hashes.get(&file.path)?.clone();
        let relative_name = file
            .path
            .strip_prefix(path)
            .ok()?
            .to_string_lossy()
            .into_owned();
        directory_files.push(DirectoryFile {
            relative_name,
            hash,
            physical_bytes: file.physical_bytes,
            logical_bytes: file.logical_bytes,
        });
    }
    if directory_files.is_empty() {
        return None;
    }
    directory_files.sort_by(|left, right| left.relative_name.cmp(&right.relative_name));
    let physical_bytes = directory_files.iter().map(|file| file.physical_bytes).sum();
    let logical_bytes = directory_files.iter().map(|file| file.logical_bytes).sum();
    let modified = metadata_modified(path);
    Some(DirectorySignature {
        path: path.to_path_buf(),
        files: directory_files,
        physical_bytes,
        logical_bytes,
        modified,
    })
}

fn directory_signature_key(signature: &DirectorySignature) -> String {
    let mut hasher = Hasher::new();
    for file in &signature.files {
        hasher.update(file.relative_name.as_bytes());
        hasher.update(&[0]);
        hasher.update(file.hash.as_bytes());
        hasher.update(&[0]);
    }
    hasher.finalize().to_hex().to_string()
}

fn directory_candidates(
    root: &Path,
    candidates: &[FileCandidate],
    token: &ScanToken,
) -> HashMap<PathBuf, Vec<FileCandidate>> {
    let mut directories: HashMap<PathBuf, Vec<FileCandidate>> = HashMap::new();
    for candidate in candidates {
        if token.is_cancelled() {
            return HashMap::new();
        }
        let mut current = candidate.path.parent();
        while let Some(directory) = current {
            if directory == root || directory.starts_with("/System") {
                break;
            }
            if should_skip_directory(directory) {
                current = directory.parent();
                continue;
            }
            directories
                .entry(directory.to_path_buf())
                .or_default()
                .push(candidate.clone());
            current = directory.parent();
        }
    }
    directories
}

fn duplicate_folder_directories(
    directory_candidates: &HashMap<PathBuf, Vec<FileCandidate>>,
) -> HashSet<PathBuf> {
    let mut by_shape: HashMap<String, Vec<PathBuf>> = HashMap::new();
    for (directory, files) in directory_candidates {
        by_shape
            .entry(directory_shape_key(directory, files))
            .or_default()
            .push(directory.to_path_buf());
    }

    by_shape
        .values()
        .filter(|directories| directories.len() >= 2)
        .flat_map(|directories| directories.iter().cloned())
        .collect()
}

fn folder_groups(
    candidates: &[FileCandidate],
    directory_candidates: &HashMap<PathBuf, Vec<FileCandidate>>,
    hashes: &HashMap<PathBuf, String>,
    token: &ScanToken,
) -> (Vec<DuplicateGroup>, HashSet<PathBuf>) {
    let duplicate_directories = duplicate_folder_directories(directory_candidates);
    let signatures: Vec<DirectorySignature> = duplicate_directories
        .into_par_iter()
        .filter_map(|directory| {
            if token.is_cancelled() {
                return None;
            }
            directory_candidates
                .get(&directory)
                .and_then(|files| directory_signature(&directory, files, &hashes))
        })
        .collect();
    let mut by_signature: HashMap<String, Vec<DirectorySignature>> = HashMap::new();
    for signature in signatures {
        by_signature
            .entry(directory_signature_key(&signature))
            .or_default()
            .push(signature);
    }

    let mut grouped_paths = HashSet::new();
    let mut groups = Vec::new();
    for (signature_key, mut directories) in by_signature {
        if token.is_cancelled() {
            return (Vec::new(), HashSet::new());
        }
        if directories.len() < 2 {
            continue;
        }
        directories.sort_by(|left, right| {
            left.path
                .components()
                .count()
                .cmp(&right.path.components().count())
                .then_with(|| left.path.cmp(&right.path))
        });
        let mut selected = Vec::new();
        for directory in directories {
            if selected
                .iter()
                .any(|parent: &DirectorySignature| directory.path.starts_with(&parent.path))
            {
                continue;
            }
            selected.push(directory);
        }
        if selected.len() < 2 {
            continue;
        }

        selected.sort_by_key(|directory| {
            (
                u8::from(noisy_path(&directory.path)),
                u8::from(noisy_name(&directory.path)),
                directory.modified,
                directory.path.clone(),
            )
        });
        let keep_path = selected[0].path.clone();
        let members = selected
            .iter()
            .map(|directory| {
                duplicate_member(
                    &directory.path,
                    directory.physical_bytes,
                    directory.logical_bytes,
                    directory.modified,
                    directory.path == keep_path,
                    source_label(&directory.path),
                )
            })
            .collect::<Vec<_>>();
        let reclaimable = members
            .iter()
            .filter(|member| !member.is_keep_recommended)
            .map(|member| member.physical_bytes)
            .sum();
        for candidate in candidates {
            if selected
                .iter()
                .any(|directory| candidate.path.starts_with(&directory.path))
            {
                grouped_paths.insert(candidate.path.clone());
            }
        }
        groups.push(DuplicateGroup {
            id: format!("folder:{signature_key}"),
            title: selected[0]
                .path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| "Duplicate folders".to_owned()),
            subtitle: format!(
                "{} identical folders · Keep 1, reclaim {}",
                members.len(),
                human_bytes(reclaimable)
            ),
            kind: DuplicateKind::DuplicateFolder,
            category: "Duplicate Folders".to_owned(),
            single_item_bytes: members[0].physical_bytes,
            reclaimable_physical_bytes: reclaimable,
            members,
        });
    }
    (groups, grouped_paths)
}

fn package_entry(
    path: &Path,
    source_label: &str,
    group_key: String,
    version_key: String,
    token: &ScanToken,
) -> Option<PackageEntry> {
    if token.is_cancelled() || !path.is_dir() {
        return None;
    }
    let (physical_bytes, logical_bytes) = calculate_dir_footprint_cancellable(path, token);
    if token.is_cancelled() || (physical_bytes == 0 && logical_bytes == 0) {
        return None;
    }
    Some(PackageEntry {
        path: path.to_path_buf(),
        name: path
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| "Runtime".to_owned()),
        source_label: source_label.to_owned(),
        physical_bytes,
        logical_bytes,
        modified: metadata_modified(path),
        group_key,
        version_key,
    })
}

fn child_directories(path: &Path) -> Vec<PathBuf> {
    fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect()
}

/// Package folders that live outside the scanned root. Passing them in, rather
/// than reading the host's real Homebrew inside the scan, lets tests run against
/// a simulated machine only.
#[derive(Clone, Debug, Default)]
struct SystemRoots {
    cellars: Vec<PathBuf>,
    npm_modules: Vec<PathBuf>,
}

impl SystemRoots {
    /// The real Homebrew install. Only `/opt/homebrew` is included: System Armor
    /// refuses to delete anywhere else in `/opt` or `/usr`, so listing
    /// `/usr/local` packages here would offer copies that cannot be removed.
    fn host() -> Self {
        Self {
            cellars: vec![PathBuf::from("/opt/homebrew/Cellar")],
            npm_modules: vec![PathBuf::from("/opt/homebrew/lib/node_modules")],
        }
    }

    /// A machine with no installs outside the scanned root.
    fn none() -> Self {
        Self::default()
    }

    /// Scanning a real home folder (or `/`) includes the host's installs;
    /// scanning anything else, such as a test directory, does not.
    fn for_scan_root(root: &Path) -> Self {
        if root == Path::new("/") || root.starts_with("/Users/") {
            Self::host()
        } else {
            Self::none()
        }
    }
}

fn package_entries(
    root: &Path,
    system_roots: &SystemRoots,
    token: &ScanToken,
) -> Vec<PackageEntry> {
    let mut entries = Vec::new();
    let home = root;
    let mut cellar_roots = vec![
        root.join("opt/homebrew/Cellar"),
        root.join("usr/local/Cellar"),
    ];
    cellar_roots.extend(system_roots.cellars.iter().cloned());
    for cellar in cellar_roots {
        for formula in child_directories(&cellar) {
            if token.is_cancelled() {
                return Vec::new();
            }
            let name = formula
                .file_name()
                .map(|value| value.to_string_lossy().into_owned())
                .unwrap_or_default();
            for version in child_directories(&formula) {
                let version_name = version
                    .file_name()
                    .map(|value| value.to_string_lossy().into_owned())
                    .unwrap_or_default();
                if let Some(entry) =
                    package_entry(&version, "Homebrew", name.clone(), version_name, token)
                {
                    entries.push(entry);
                }
            }
        }
    }

    let runtime_roots = [
        (home.join(".pyenv/versions"), "pyenv", "python"),
        (home.join("miniconda3/envs"), "Conda", "python"),
        (home.join("anaconda3/envs"), "Conda", "python"),
        (home.join("miniforge3/envs"), "Conda", "python"),
        (home.join(".local/share/uv/python"), "uv", "python"),
        (
            home.join("Library/Application Support/uv/python"),
            "uv",
            "python",
        ),
        (home.join(".nvm/versions/node"), "nvm", "node"),
        (
            home.join("Library/Application Support/fnm/node-versions"),
            "fnm",
            "node",
        ),
        (home.join(".local/share/fnm/node-versions"), "fnm", "node"),
        (home.join(".rustup/toolchains"), "rustup", "rust"),
    ];
    for (runtime_root, label, family) in runtime_roots {
        for path in child_directories(&runtime_root) {
            if token.is_cancelled() {
                return Vec::new();
            }
            let version_name = path
                .file_name()
                .map(|value| value.to_string_lossy().into_owned())
                .unwrap_or_default();
            if let Some(entry) = package_entry(&path, label, family.to_owned(), version_name, token)
            {
                entries.push(entry);
            }
        }
    }

    let mut npm_roots = vec![
        root.join("opt/homebrew/lib/node_modules"),
        root.join("usr/local/lib/node_modules"),
    ];
    npm_roots.extend(system_roots.npm_modules.iter().cloned());
    for npm_root in npm_roots {
        for path in child_directories(&npm_root) {
            if token.is_cancelled() {
                return Vec::new();
            }
            let name = path
                .file_name()
                .map(|value| value.to_string_lossy().into_owned())
                .unwrap_or_default();
            if matches!(name.as_str(), "npm" | "corepack") {
                continue;
            }
            if let Some(entry) = package_entry(&path, "Global npm", name.clone(), name, token) {
                entries.push(entry);
            }
        }
    }
    entries
}

fn package_member(entry: &PackageEntry, keep: bool) -> DuplicateMember {
    duplicate_member(
        &entry.path,
        entry.physical_bytes,
        entry.logical_bytes,
        entry.modified,
        keep,
        entry.source_label.clone(),
    )
}

fn make_package_group(id: String, title: String, entries: Vec<PackageEntry>) -> DuplicateGroup {
    let mut entries = entries;
    entries.sort_by(|left, right| right.version_key.cmp(&left.version_key));
    let keep_path = entries[0].path.clone();
    let members = entries
        .iter()
        .map(|entry| package_member(entry, entry.path == keep_path))
        .collect::<Vec<_>>();
    let reclaimable = members
        .iter()
        .filter(|member| !member.is_keep_recommended)
        .map(|member| member.physical_bytes)
        .sum();
    DuplicateGroup {
        id,
        title,
        subtitle: format!(
            "{} redundant installations · Keep 1, reclaim {}",
            members.len(),
            human_bytes(reclaimable)
        ),
        kind: DuplicateKind::DuplicatePackage,
        category: "Redundant Packages & Runtimes".to_owned(),
        single_item_bytes: members[0].physical_bytes,
        reclaimable_physical_bytes: reclaimable,
        members,
    }
}

fn package_groups(
    root: &Path,
    system_roots: &SystemRoots,
    token: &ScanToken,
) -> Vec<DuplicateGroup> {
    let entries = package_entries(root, system_roots, token);
    let mut groups = Vec::new();

    let mut by_formula: HashMap<String, Vec<PackageEntry>> = HashMap::new();
    for entry in entries
        .iter()
        .filter(|entry| entry.source_label == "Homebrew")
    {
        by_formula
            .entry(entry.group_key.clone())
            .or_default()
            .push(entry.clone());
    }
    for (formula, versions) in by_formula {
        if versions.len() >= 2 {
            groups.push(make_package_group(
                format!("package:homebrew:{formula}"),
                format!("Homebrew {formula} versions"),
                versions,
            ));
        }
    }

    for family in ["python", "node", "rust"] {
        let family_entries: Vec<_> = entries
            .iter()
            .filter(|entry| entry.group_key == family)
            .cloned()
            .collect();
        let distinct_sources: HashSet<_> = family_entries
            .iter()
            .map(|entry| entry.source_label.as_str())
            .collect();
        if family_entries.len() >= 2 && distinct_sources.len() >= 2 {
            groups.push(make_package_group(
                format!("package:family:{family}"),
                format!("{} runtime family", family.to_ascii_uppercase()),
                family_entries,
            ));
        }
    }

    let mut by_cli_name: HashMap<String, Vec<PackageEntry>> = HashMap::new();
    for entry in entries
        .iter()
        .filter(|entry| matches!(entry.source_label.as_str(), "Homebrew" | "Global npm"))
    {
        by_cli_name
            .entry(entry.name.trim_start_matches('@').to_ascii_lowercase())
            .or_default()
            .push(entry.clone());
    }
    for (name, entries) in by_cli_name {
        let sources: HashSet<_> = entries
            .iter()
            .map(|entry| entry.source_label.as_str())
            .collect();
        if entries.len() >= 2 && sources.len() >= 2 {
            groups.push(make_package_group(
                format!("package:cli:{name}"),
                format!("Duplicate CLI {name}"),
                entries,
            ));
        }
    }
    groups
}

fn scan_duplicates_impl(
    root: &Path,
    min_size_bytes: u64,
    token: &ScanToken,
    system_roots: &SystemRoots,
) -> Vec<DuplicateGroup> {
    crate::configure_scan_thread_pool();
    let threshold = if min_size_bytes == 0 {
        DEFAULT_MIN_SIZE_BYTES
    } else {
        min_size_bytes
    };
    // A cancelled stage yields partial data, and groups built from partial
    // hashes could be wrong. Every stage boundary therefore bails out with no
    // results rather than continuing with incomplete input.
    let candidates = walk_files(root, threshold, token);
    if token.is_cancelled() {
        return Vec::new();
    }
    let directory_candidates = directory_candidates(root, &candidates, token);
    if token.is_cancelled() {
        return Vec::new();
    }
    let folder_hash_paths: HashSet<PathBuf> = duplicate_folder_directories(&directory_candidates)
        .iter()
        .filter_map(|directory| directory_candidates.get(directory))
        .flat_map(|files| files.iter().map(|file| file.path.clone()))
        .collect();
    let file_hash_paths = edge_collision_candidates(&candidates, token);
    if token.is_cancelled() {
        return Vec::new();
    }
    let mut hash_paths = folder_hash_paths;
    hash_paths.extend(file_hash_paths.iter().cloned());
    let hashes = full_hashes(hash_paths, token);
    if token.is_cancelled() {
        return Vec::new();
    }
    let (mut groups, grouped_paths) =
        folder_groups(&candidates, &directory_candidates, &hashes, token);
    if token.is_cancelled() {
        return Vec::new();
    }
    let mut by_full_hash: HashMap<String, Vec<FileCandidate>> = HashMap::new();
    for candidate in candidates {
        if file_hash_paths.contains(&candidate.path) && !grouped_paths.contains(&candidate.path) {
            if let Some(full_hash) = hashes.get(&candidate.path) {
                by_full_hash
                    .entry(full_hash.clone())
                    .or_default()
                    .push(candidate);
            }
        }
    }
    for (hash, files) in by_full_hash {
        if files.len() >= 2 {
            groups.push(make_file_group(&hash, files));
        }
    }
    groups.extend(package_groups(root, system_roots, token));
    if token.is_cancelled() {
        return Vec::new();
    }
    groups.sort_by(|left, right| {
        right
            .reclaimable_physical_bytes
            .cmp(&left.reclaimable_physical_bytes)
    });
    groups
}

#[uniffi::export]
pub fn scan_duplicates(root_path: String, min_size_bytes: u64) -> Vec<DuplicateGroup> {
    let token = ScanToken::begin();
    crate::configure_scan_thread_pool();
    let root = Path::new(&root_path);
    scan_duplicates_impl(
        root,
        min_size_bytes,
        &token,
        &SystemRoots::for_scan_root(root),
    )
}

#[cfg(test)]
mod tests {
    use super::{full_hash, scan_duplicates_impl, SystemRoots};
    use crate::cancel::ScanToken;
    use crate::{DuplicateGroup, DuplicateKind};
    use std::fs::{self, File};
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::mpsc;
    use std::time::Duration;

    /// Scans with no system roots, so a test only ever sees its own directory.
    fn scan(root: &Path, min_size_bytes: u64) -> Vec<DuplicateGroup> {
        scan_with(root, min_size_bytes, &SystemRoots::none())
    }

    fn scan_with(
        root: &Path,
        min_size_bytes: u64,
        system_roots: &SystemRoots,
    ) -> Vec<DuplicateGroup> {
        scan_duplicates_impl(root, min_size_bytes, &ScanToken::never(), system_roots)
    }

    fn root(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("rustdisk-duplicates-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write(path: &PathBuf, bytes: &[u8]) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        File::create(path).unwrap().write_all(bytes).unwrap();
    }

    #[test]
    fn cancelled_duplicate_scan_returns_nothing_even_when_duplicates_exist() {
        let root = root("cancelled");
        let bytes = vec![5u8; 8192];
        write(&root.join("one.bin"), &bytes);
        write(&root.join("two.bin"), &bytes);
        assert!(!scan(&root, 4096).is_empty());

        let cancelled = ScanToken::never();
        cancelled.cancel();
        assert!(scan_duplicates_impl(&root, 4096, &cancelled, &SystemRoots::none()).is_empty());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn full_hash_stops_in_the_middle_of_a_huge_file_when_cancelled() {
        let root = root("hash-cancel");
        // Sparse 2 GiB file: costs no disk space but takes far longer to hash
        // than the cancel delay below, so the hash can only return `None` by
        // noticing the token mid-file.
        let huge = root.join("huge.bin");
        File::create(&huge)
            .unwrap()
            .set_len(2 * 1024 * 1024 * 1024)
            .unwrap();

        let token = ScanToken::never();
        let worker_token = token.clone();
        let worker_path = huge.clone();
        let (sender, receiver) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            sender.send(full_hash(&worker_path, &worker_token)).unwrap();
        });

        std::thread::sleep(Duration::from_millis(20));
        token.cancel();
        let result = receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("hashing did not stop within 5s of cancellation");
        worker.join().unwrap();
        assert!(result.is_none(), "cancelled hash must not produce a digest");

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn three_stage_file_deduplication_keeps_one_original() {
        let root = root("files");
        let bytes = vec![7u8; 8192];
        write(&root.join("original.bin"), &bytes);
        write(&root.join("Downloads/copy.bin"), &bytes);
        write(&root.join("copy (1).bin"), &bytes);
        write(&root.join("different.bin"), &vec![8u8; 8192]);

        let groups = scan(&root, 4096);
        let group = groups
            .iter()
            .find(|group| group.kind == DuplicateKind::DuplicateFile)
            .unwrap();
        assert_eq!(group.members.len(), 3);
        assert_eq!(
            group
                .members
                .iter()
                .filter(|member| member.is_keep_recommended)
                .count(),
            1
        );
        assert!(group
            .members
            .iter()
            .any(|member| member.name == "original.bin" && member.is_keep_recommended));
        assert_eq!(
            group.reclaimable_physical_bytes,
            group.single_item_bytes * 2
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn hardlinks_are_not_reclaimable_duplicates() {
        let root = root("hardlink");
        let original = root.join("original.bin");
        write(&original, &vec![1u8; 8192]);
        std::fs::hard_link(&original, root.join("hardlink.bin")).unwrap();
        assert!(!scan(&root, 4096)
            .iter()
            .any(|group| group.kind == DuplicateKind::DuplicateFile));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn identical_folders_roll_up_without_child_file_groups() {
        let root = root("folders");
        let bytes = vec![3u8; 8192];
        write(&root.join("one/data.bin"), &bytes);
        write(&root.join("two/data.bin"), &bytes);
        let groups = scan(&root, 4096);
        assert_eq!(
            groups
                .iter()
                .filter(|group| group.kind == DuplicateKind::DuplicateFolder)
                .count(),
            1
        );
        assert_eq!(
            groups
                .iter()
                .filter(|group| group.kind == DuplicateKind::DuplicateFile)
                .count(),
            0
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn simulated_package_versions_and_python_managers_roll_up() {
        let root = root("packages");
        write(
            &root.join("opt/homebrew/Cellar/python@3.12/3.12.1/bin/python"),
            b"python",
        );
        write(
            &root.join("opt/homebrew/Cellar/python@3.12/3.12.2/bin/python"),
            b"python-new",
        );
        write(&root.join(".pyenv/versions/3.12.2/bin/python"), b"python");
        let groups = scan(&root, 4096);
        let package_groups: Vec<_> = groups
            .iter()
            .filter(|group| group.kind == DuplicateKind::DuplicatePackage)
            .collect();
        assert!(package_groups
            .iter()
            .any(|group| group.title.contains("python")));
        assert!(package_groups.iter().all(|group| group
            .members
            .iter()
            .filter(|member| member.is_keep_recommended)
            .count()
            == 1));
        let brew_group = package_groups
            .iter()
            .find(|group| group.title.contains("Homebrew"))
            .unwrap();
        assert!(brew_group
            .members
            .iter()
            .any(|member| member.path.contains("3.12.2") && member.is_keep_recommended));

        // Nothing from the machine running the test may leak into the result.
        let canonical_root = fs::canonicalize(&root).unwrap();
        assert!(groups
            .iter()
            .flat_map(|group| &group.members)
            .all(|member| Path::new(&member.path).starts_with(&canonical_root)));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn injected_system_roots_stand_in_for_the_hosts_homebrew() {
        let root = root("injected-roots");
        let system = root.join("pretend-host/Cellar");
        let scanned = root.join("scanned-home");
        write(&system.join("python@3.12/3.12.1/bin/python"), b"python");
        write(&system.join("python@3.12/3.12.2/bin/python"), b"python-new");
        fs::create_dir_all(&scanned).unwrap();

        let has_brew_group = |groups: &[DuplicateGroup]| {
            groups
                .iter()
                .any(|group| group.kind == DuplicateKind::DuplicatePackage)
        };
        assert!(
            !has_brew_group(&scan(&scanned, 4096)),
            "without system roots the scan sees only its own directory"
        );
        let injected = SystemRoots {
            cellars: vec![system],
            npm_modules: Vec::new(),
        };
        assert!(has_brew_group(&scan_with(&scanned, 4096, &injected)));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn host_system_roots_are_used_only_for_real_home_scans_and_only_where_cleanup_is_allowed() {
        for roots in [
            SystemRoots::for_scan_root(Path::new("/Users/someone")),
            SystemRoots::for_scan_root(Path::new("/")),
        ] {
            assert_eq!(roots.cellars, [PathBuf::from("/opt/homebrew/Cellar")]);
            assert_eq!(
                roots.npm_modules,
                [PathBuf::from("/opt/homebrew/lib/node_modules")]
            );
        }

        let roots = SystemRoots::for_scan_root(Path::new("/var/tmp/rustdisk-not-a-home"));
        assert!(roots.cellars.is_empty() && roots.npm_modules.is_empty());
    }
}
