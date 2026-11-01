use crate::cancel::ScanToken;
use crate::{ProjectActivity, RiskTier, ScannedItem};
use jwalk::{Parallelism, WalkDir};
use rayon::prelude::*;
use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const BYTES_PER_BLOCK: u64 = 512;
const DAY_SECONDS: u64 = 86_400;

pub(crate) fn calculate_file_footprint(path: &Path) -> Option<(u64, u64)> {
    let metadata = fs::symlink_metadata(path).ok()?;
    Some((
        metadata.blocks().saturating_mul(BYTES_PER_BLOCK),
        metadata.len(),
    ))
}

/// Measures a directory without a way to cancel it. Used by cleanup, which must
/// always measure completely.
pub(crate) fn calculate_dir_footprint(dir: &Path) -> (u64, u64) {
    calculate_dir_footprint_cancellable(dir, &ScanToken::never())
}

/// Measures a directory, stopping early once `token` is cancelled. The returned
/// totals are partial after cancellation, so callers must check the token and
/// discard them.
pub(crate) fn calculate_dir_footprint_cancellable(dir: &Path, token: &ScanToken) -> (u64, u64) {
    let mut physical = 0u64;
    let mut logical = 0u64;
    let walk_token = token.clone();

    // Serial on purpose. This runs inside rayon `par_iter` closures on a pool
    // capped at two threads. jwalk's default mode would spawn onto that same
    // pool while the closure blocks waiting for it, starve, and abort the walk
    // after its 1s busy timeout, silently under-counting the folder. The outer
    // `par_iter` already provides the parallelism.
    for entry in WalkDir::new(dir)
        .parallelism(Parallelism::Serial)
        .skip_hidden(false)
        .follow_links(false)
        .process_read_dir(move |_, _, _, children| {
            if walk_token.is_cancelled() {
                children.clear();
            }
        })
        .into_iter()
        .flatten()
    {
        if token.is_cancelled() {
            break;
        }
        if entry.file_type().is_file() {
            if let Some((file_physical, file_logical)) = calculate_file_footprint(&entry.path()) {
                physical = physical.saturating_add(file_physical);
                logical = logical.saturating_add(file_logical);
            }
        }
    }

    (physical, logical)
}

fn days_since_modified(path: &Path) -> u64 {
    let modified = fs::symlink_metadata(path)
        .and_then(|metadata| metadata.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH);

    SystemTime::now()
        .duration_since(modified)
        .unwrap_or(Duration::ZERO)
        .as_secs()
        / DAY_SECONDS
}

fn item_for_path(
    path: &Path,
    category: &str,
    risk: RiskTier,
    activity: ProjectActivity,
    token: &ScanToken,
) -> Option<ScannedItem> {
    let (physical_bytes, logical_bytes) = if path.is_dir() {
        calculate_dir_footprint_cancellable(path, token)
    } else {
        calculate_file_footprint(path)?
    };
    if token.is_cancelled() {
        return None;
    }

    let name = path
        .file_name()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned());
    let path_string = path.to_string_lossy().into_owned();

    Some(ScannedItem {
        id: path_string.clone(),
        name,
        path: path_string,
        physical_bytes,
        logical_bytes,
        category: category.to_owned(),
        risk,
        activity,
        days_since_modified: days_since_modified(path),
        ecosystem: String::new(),
        project_root: String::new(),
        restore_hint: String::new(),
        has_git: false,
    })
}

fn direct_children(root: &Path, directories_only: bool) -> Vec<PathBuf> {
    if root.is_file() {
        return vec![root.to_path_buf()];
    }

    fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| !directories_only || path.is_dir())
        .collect()
}

#[derive(Clone)]
struct CacheSource {
    root: PathBuf,
    category: &'static str,
    risk: RiskTier,
    enumerate_children: bool,
    directories_only: bool,
    minimum_physical_bytes: u64,
}

fn cache_source(
    root: PathBuf,
    category: &'static str,
    risk: RiskTier,
    enumerate_children: bool,
    directories_only: bool,
    minimum_physical_bytes: u64,
) -> CacheSource {
    CacheSource {
        root,
        category,
        risk,
        enumerate_children,
        directories_only,
        minimum_physical_bytes,
    }
}

fn library_cache_category(path: &Path) -> &'static str {
    let name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();

    if name == "pnpm"
        || name == "yarn"
        || name == "ms-playwright"
        || name == "cypress"
        || name == "npm"
    {
        "Web & Node Caches"
    } else if name == "homebrew" {
        "Xcode & Homebrew Caches"
    } else {
        "macOS App Caches"
    }
}

fn safe_cache_sources(home_dir: &Path) -> Vec<CacheSource> {
    const FIVE_MIB: u64 = 5 * 1024 * 1024;

    vec![
        cache_source(
            home_dir.join("Library/Caches"),
            "System & App Cache",
            RiskTier::Safe,
            true,
            true,
            FIVE_MIB,
        ),
        cache_source(
            home_dir.join("Library/Logs"),
            "macOS App Caches",
            RiskTier::Safe,
            true,
            false,
            0,
        ),
        cache_source(
            home_dir.join(".npm/_cacache"),
            "Web & Node Caches",
            RiskTier::Safe,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join(".cache/pip"),
            "AI & Python Caches",
            RiskTier::Safe,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join(".cache/uv"),
            "AI & Python Caches",
            RiskTier::Safe,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join(".cache/torch"),
            "AI & Python Caches",
            RiskTier::Safe,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join(".cache/huggingface"),
            "AI & Python Caches",
            RiskTier::Safe,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join(".gradle/caches"),
            "JVM & Build Caches",
            RiskTier::Rebuildable,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join(".m2/repository"),
            "JVM & Build Caches",
            RiskTier::Rebuildable,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join(".cargo/registry/cache"),
            "JVM & Build Caches",
            RiskTier::Rebuildable,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join("Library/Caches/Homebrew"),
            "Xcode & Homebrew Caches",
            RiskTier::Safe,
            false,
            false,
            FIVE_MIB,
        ),
        cache_source(
            home_dir.join("Library/Developer/Xcode/DerivedData"),
            "Xcode & Homebrew Caches",
            RiskTier::Rebuildable,
            false,
            false,
            0,
        ),
        cache_source(
            home_dir.join("Library/Developer/CoreSimulator/Caches"),
            "Xcode & Homebrew Caches",
            RiskTier::Rebuildable,
            false,
            false,
            0,
        ),
    ]
}

fn scan_cache_sources(sources: &[CacheSource], token: &ScanToken) -> Vec<ScannedItem> {
    let mut items: Vec<ScannedItem> = sources
        .par_iter()
        .flat_map_iter(|source| {
            let paths = if token.is_cancelled() {
                Vec::new()
            } else if source.enumerate_children {
                direct_children(&source.root, source.directories_only)
            } else {
                vec![source.root.clone()]
            };

            paths.into_iter().filter_map(|path| {
                if token.is_cancelled() {
                    return None;
                }
                let category = if source.root.ends_with("Library/Caches") {
                    library_cache_category(&path)
                } else {
                    source.category
                };
                let item = item_for_path(
                    &path,
                    category,
                    source.risk,
                    ProjectActivity::NotProject,
                    token,
                )?;
                (item.physical_bytes >= source.minimum_physical_bytes).then_some(item)
            })
        })
        .filter(|item| item.physical_bytes > 0)
        .collect();
    if token.is_cancelled() {
        return Vec::new();
    }

    let mut seen_paths = HashSet::new();
    items.retain(|item| seen_paths.insert(item.path.clone()));
    items.sort_by(|left, right| right.physical_bytes.cmp(&left.physical_bytes));
    items
}

/// Scans known rebuildable cache locations under the current user's home directory.
#[uniffi::export]
pub fn scan_safe_caches(home_dir: String) -> Vec<ScannedItem> {
    let token = ScanToken::begin();
    crate::configure_scan_thread_pool();
    let home = Path::new(&home_dir);
    scan_cache_sources(&safe_cache_sources(home), &token)
}

/// The only part of `/opt` the large-file scan enters. System Armor refuses to
/// delete anywhere else in `/opt`, so listing it would tempt users with items
/// that cannot be removed.
const HOMEBREW_PREFIX: &str = "/opt/homebrew";

/// Where the large-file scan looks: the home folder, plus Homebrew's prefix.
fn large_file_roots(home_root: &Path) -> Vec<PathBuf> {
    vec![home_root.to_path_buf(), PathBuf::from(HOMEBREW_PREFIX)]
}

/// Paths the large-file scan never lists or descends into. Keep this in step
/// with the deletion guardrails in `cleaner::SystemArmor`.
fn should_skip_large_file_path(path: &Path) -> bool {
    // `/usr` entirely (it covers `/usr/bin` and `/usr/local`).
    const PROTECTED_ROOTS: [&str; 5] = ["/System", "/bin", "/sbin", "/usr", "/.Trash"];

    PROTECTED_ROOTS
        .iter()
        .map(Path::new)
        .any(|root| path.starts_with(root))
        || (path.starts_with("/opt") && !path.starts_with(HOMEBREW_PREFIX))
        || path.components().any(|component| {
            let value = component.as_os_str().to_string_lossy();
            matches!(value.as_ref(), ".git" | ".Trash")
        })
}

const BUNDLE_SUFFIXES: [&str; 8] = [
    ".app",
    ".framework",
    ".photoslibrary",
    ".tvlibrary",
    ".musiclibrary",
    ".xcodeproj",
    ".xcworkspace",
    ".playground",
];

const PROJECT_ARTIFACT_NAMES: [&str; 19] = [
    "node_modules",
    ".next",
    ".nuxt",
    ".turbo",
    ".parcel-cache",
    ".vite",
    "dist",
    ".venv",
    "venv",
    ".conda",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    "target",
    "build",
    ".gradle",
    ".build",
    "Pods",
];

fn has_path_component(path: &Path, name: &str) -> bool {
    path.components()
        .any(|component| component.as_os_str() == name)
}

fn is_macos_bundle(path: &Path) -> bool {
    let name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    BUNDLE_SUFFIXES.iter().any(|suffix| name.ends_with(suffix))
}

fn is_known_dev_cache_or_runtime(path: &Path) -> bool {
    const KNOWN_ROOT_SUFFIXES: [&str; 22] = [
        "Library/Caches",
        "Library/Logs",
        ".npm/_cacache",
        ".cache/pip",
        ".cache/uv",
        ".cache/torch",
        ".cache/huggingface",
        ".gradle/caches",
        ".m2/repository",
        ".cargo/registry/cache",
        "Library/Caches/Homebrew",
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/CoreSimulator/Caches",
        ".pyenv",
        ".rustup",
        ".nvm",
        ".fnm",
        ".conda",
        "miniconda3",
        "anaconda3",
        "miniforge3",
        ".local/share/uv",
    ];

    PROJECT_ARTIFACT_NAMES
        .iter()
        .any(|name| has_path_component(path, name))
        || KNOWN_ROOT_SUFFIXES.iter().any(|suffix| {
            path.to_string_lossy()
                .split("/")
                .collect::<Vec<_>>()
                .windows(suffix.split('/').count())
                .any(|window| window.join("/") == *suffix)
        })
        || path.starts_with("/opt/homebrew/Cellar")
        || path.starts_with("/opt/homebrew/Caskroom")
        || path.starts_with("/usr/local/Cellar")
        || path.starts_with("/usr/local/Caskroom")
}

fn category_for_large_file(path: &Path) -> &'static str {
    let extension = path
        .extension()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();

    if matches!(
        extension.as_str(),
        "dmg" | "iso" | "pkg" | "mpkg" | "xip" | "ipsw"
    ) {
        "Disk Images & Installers"
    } else if matches!(
        extension.as_str(),
        "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "zst" | "7z" | "rar" | "bak"
    ) {
        "Archives & Backups"
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
    } else if matches!(
        extension.as_str(),
        "mp4" | "mov" | "mkv" | "webm" | "avi" | "m4v" | "wav" | "flac" | "aiff" | "psd" | "psb"
    ) {
        "Video & Audio Media"
    } else if matches!(
        extension.as_str(),
        "raw" | "qcow2" | "vmdk" | "vdi" | "vhd" | "ova" | "utm"
    ) {
        "Virtual Machines & Disks"
    } else {
        "Other Large Files"
    }
}

fn risk_for_large_file(path: &Path, home_root: &Path, category: &str) -> RiskTier {
    if category == "Virtual Machines & Disks" {
        RiskTier::HighRiskCli
    } else if category == "Disk Images & Installers"
        || path.starts_with(home_root.join("Downloads"))
    {
        RiskTier::Safe
    } else {
        RiskTier::Rebuildable
    }
}

fn scan_large_files_from_roots(
    roots: &[PathBuf],
    home_root: &Path,
    threshold_bytes: u64,
    include_dev_caches: bool,
    token: &ScanToken,
) -> Vec<ScannedItem> {
    let mut items = Vec::new();
    let mut seen_inodes = HashSet::new();

    for root in roots {
        if token.is_cancelled() {
            return Vec::new();
        }
        if !root.exists() || should_skip_large_file_path(root) || is_macos_bundle(root) {
            continue;
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
                        if should_skip_large_file_path(&path)
                            || is_macos_bundle(&path)
                            || (!include_dev_caches && is_known_dev_cache_or_runtime(&path))
                        {
                            entry.read_children_path = None;
                        }
                    }
                }
            });

        for entry in walker.into_iter().flatten() {
            if token.is_cancelled() {
                return Vec::new();
            }
            let path = entry.path();

            if !entry.file_type().is_file()
                || should_skip_large_file_path(&path)
                || (!include_dev_caches && is_known_dev_cache_or_runtime(&path))
            {
                continue;
            }

            let Some((physical_bytes, _)) = calculate_file_footprint(&path) else {
                continue;
            };
            if physical_bytes < threshold_bytes {
                continue;
            }

            // Avoid listing the same hard-linked inode more than once. APFS clones
            // remain intentionally visible because their allocated blocks can differ.
            if let Ok(metadata) = fs::symlink_metadata(&path) {
                let inode_key = (metadata.dev(), metadata.ino());
                if !seen_inodes.insert(inode_key) {
                    continue;
                }
            }

            let category = category_for_large_file(&path);
            let risk = risk_for_large_file(&path, home_root, category);

            // The file can vanish between the walk and this read, so a missing item is skipped.
            let Some(mut item) =
                item_for_path(&path, category, risk, ProjectActivity::NotProject, token)
            else {
                continue;
            };
            item.name = path
                .file_name()
                .map(|value| value.to_string_lossy().into_owned())
                .unwrap_or_else(|| item.name.clone());
            items.push(item);
        }
    }

    if token.is_cancelled() {
        return Vec::new();
    }
    items.sort_by(|left, right| right.physical_bytes.cmp(&left.physical_bytes));
    items
}

fn scan_large_files_impl(
    root_path: String,
    threshold_bytes: u64,
    include_dev_caches: bool,
    token: &ScanToken,
) -> Vec<ScannedItem> {
    crate::configure_scan_thread_pool();
    let home_root = PathBuf::from(&root_path);
    let roots = large_file_roots(&home_root);
    scan_large_files_from_roots(
        &roots,
        &home_root,
        threshold_bytes,
        include_dev_caches,
        token,
    )
}

/// Finds standalone files above `threshold_bytes` in the user's home directory and /opt/homebrew.
#[uniffi::export]
pub fn scan_large_files(root_path: String, threshold_bytes: u64) -> Vec<ScannedItem> {
    let token = ScanToken::begin();
    scan_large_files_impl(root_path, threshold_bytes, false, &token)
}

/// Finds large files with an explicit toggle for cache, artifact, and package-runtime internals.
#[uniffi::export]
pub fn scan_large_files_with_options(
    root_path: String,
    threshold_bytes: u64,
    include_dev_caches: bool,
) -> Vec<ScannedItem> {
    let token = ScanToken::begin();
    scan_large_files_impl(root_path, threshold_bytes, include_dev_caches, &token)
}

#[cfg(test)]
mod tests {
    use super::{
        calculate_dir_footprint_cancellable, category_for_large_file, large_file_roots,
        safe_cache_sources, scan_cache_sources, scan_large_files_from_roots,
        should_skip_large_file_path,
    };
    use crate::cancel::ScanToken;
    use crate::{purge_items, DeletionMode, RiskTier};
    use std::collections::HashSet;
    use std::fs::{self, File};
    use std::io::Write;
    use std::path::PathBuf;

    #[test]
    fn large_file_scan_uses_physical_threshold_and_sorts_descending() {
        let root = temp_root("large-files");
        fs::create_dir_all(&root).unwrap();

        let small_path = root.join("small.bin");
        File::create(&small_path)
            .unwrap()
            .write_all(b"small")
            .unwrap();

        let large_path = root.join("large.bin");
        let mut large = File::create(&large_path).unwrap();
        large.write_all(&vec![0u8; 16 * 1024]).unwrap();

        let items = scan_large_files_from_roots(
            &[root.clone()],
            &root,
            8 * 1024,
            false,
            &ScanToken::never(),
        );
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].path, large_path.to_string_lossy());

        let report = purge_items(
            vec![large_path.to_string_lossy().into_owned()],
            DeletionMode::PermanentDelete,
        );
        assert_eq!(report.deleted_items_count, 1);
        assert!(report.permanently_freed_physical_bytes > 0);
        assert!(report.errors.is_empty());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn large_file_scan_ignores_git_and_trash_paths() {
        assert!(should_skip_large_file_path(&PathBuf::from(
            "/tmp/project/.git/objects/pack"
        )));
        assert!(should_skip_large_file_path(&PathBuf::from(
            "/Users/test/.Trash/archive.dmg"
        )));
        assert!(!should_skip_large_file_path(&PathBuf::from(
            "/Users/test/archive.dmg"
        )));
        assert!(should_skip_large_file_path(&PathBuf::from(
            "/System/Library/foo"
        )));
        assert!(should_skip_large_file_path(&PathBuf::from("/usr/bin/tool")));
    }

    #[test]
    fn large_file_scan_scope_matches_the_deletion_guardrails() {
        // Skipped: System Armor would refuse to delete anything here.
        for path in [
            "/usr",
            "/usr/local/lib/libfoo.dylib",
            "/usr/lib/big.bin",
            "/opt",
            "/opt/miniconda3/pkgs/big.tar.bz2",
            "/opt/local/lib/libbig.dylib",
            "/opt/homebrew-other/big.bin",
        ] {
            assert!(
                should_skip_large_file_path(&PathBuf::from(path)),
                "{path} must be skipped"
            );
        }
        // Listed: deletable.
        for path in [
            "/opt/homebrew",
            "/opt/homebrew/share/big.bin",
            "/Users/test/Movies/big.mov",
            "/usrlike/big.bin",
        ] {
            assert!(
                !should_skip_large_file_path(&PathBuf::from(path)),
                "{path} must be scanned"
            );
        }

        assert_eq!(
            large_file_roots(&PathBuf::from("/Users/test")),
            [PathBuf::from("/Users/test"), PathBuf::from("/opt/homebrew")]
        );
    }

    #[test]
    fn large_file_categories_and_risk_tiers_are_actionable() {
        let root = temp_root("large-file-categories");
        fs::create_dir_all(&root).unwrap();
        let files = [
            ("installer.dmg", "Disk Images & Installers", RiskTier::Safe),
            ("backup.tar.gz", "Archives & Backups", RiskTier::Rebuildable),
            (
                "weights.safetensors",
                "AI Models & Datasets",
                RiskTier::Rebuildable,
            ),
            (
                "recording.mp4",
                "Video & Audio Media",
                RiskTier::Rebuildable,
            ),
            (
                "machine.qcow2",
                "Virtual Machines & Disks",
                RiskTier::HighRiskCli,
            ),
        ];

        for (name, _, _) in files {
            write_large_file(&root.join(name));
        }

        let items = scan_large_files_from_roots(
            &[root.clone()],
            &root,
            8 * 1024,
            false,
            &ScanToken::never(),
        );
        for (name, category, risk) in files {
            let item = items.iter().find(|item| item.name == name).unwrap();
            assert_eq!(item.category, category);
            assert_eq!(item.risk, risk);
            assert_eq!(category_for_large_file(&root.join(name)), category);
        }

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn large_file_scan_skips_macos_bundle_contents() {
        let root = temp_root("large-file-bundle");
        let bundle_binary = root.join("MyApp.app/Contents/MacOS/huge_binary");
        let standalone = root.join("standalone.bin");
        fs::create_dir_all(bundle_binary.parent().unwrap()).unwrap();
        write_large_file(&bundle_binary);
        write_large_file(&standalone);

        let items = scan_large_files_from_roots(
            &[root.clone()],
            &root,
            8 * 1024,
            false,
            &ScanToken::never(),
        );
        assert!(items
            .iter()
            .any(|item| item.path == standalone.to_string_lossy()));
        assert!(!items
            .iter()
            .any(|item| item.path == bundle_binary.to_string_lossy()));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn large_file_scan_toggles_dev_cache_and_artifact_exclusion() {
        let root = temp_root("large-file-scope");
        let cache_file = root.join("Library/Caches/cache.bin");
        let artifact_file = root.join("node_modules/package.bin");
        let standalone = root.join("Downloads/model.gguf");
        for path in [&cache_file, &artifact_file, &standalone] {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            write_large_file(path);
        }

        let hidden = scan_large_files_from_roots(
            &[root.clone()],
            &root,
            8 * 1024,
            false,
            &ScanToken::never(),
        );
        assert_eq!(hidden.len(), 1);
        assert_eq!(hidden[0].path, standalone.to_string_lossy());
        assert_eq!(hidden[0].risk, RiskTier::Safe);

        let included = scan_large_files_from_roots(
            &[root.clone()],
            &root,
            8 * 1024,
            true,
            &ScanToken::never(),
        );
        assert_eq!(included.len(), 3);
        assert!(included
            .iter()
            .any(|item| item.path == cache_file.to_string_lossy()));
        assert!(included
            .iter()
            .any(|item| item.path == artifact_file.to_string_lossy()));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn safe_cache_scan_enumerates_children_and_filters_tiny_cache_directories() {
        let root = temp_root("safe-caches");
        let library_caches = root.join("Library/Caches");
        let big_cache = library_caches.join("Google");
        let tiny_cache = library_caches.join("Tiny");
        let pip_cache = root.join(".cache/pip");
        fs::create_dir_all(&big_cache).unwrap();
        fs::create_dir_all(&tiny_cache).unwrap();
        fs::create_dir_all(&pip_cache).unwrap();

        File::create(big_cache.join("cache.bin"))
            .unwrap()
            .write_all(&vec![0u8; 6 * 1024 * 1024])
            .unwrap();
        File::create(tiny_cache.join("cache.bin"))
            .unwrap()
            .write_all(b"tiny")
            .unwrap();
        File::create(pip_cache.join("http-cache"))
            .unwrap()
            .write_all(b"pip")
            .unwrap();

        let items = scan_cache_sources(&safe_cache_sources(&root), &ScanToken::never());
        let paths: HashSet<_> = items.iter().map(|item| item.path.as_str()).collect();
        assert!(paths.contains(big_cache.to_string_lossy().as_ref()));
        assert!(!paths.contains(tiny_cache.to_string_lossy().as_ref()));
        assert!(paths.contains(pip_cache.to_string_lossy().as_ref()));
        assert_eq!(
            items
                .iter()
                .find(|item| item.path == big_cache.to_string_lossy())
                .map(|item| item.category.as_str()),
            Some("macOS App Caches")
        );

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn safe_cache_sources_cover_required_known_roots() {
        let root = PathBuf::from("/Users/test");
        let source_roots: HashSet<_> = safe_cache_sources(&root)
            .iter()
            .map(|source| source.root.to_string_lossy().into_owned())
            .collect();

        for required in [
            "/Users/test/Library/Caches",
            "/Users/test/Library/Logs",
            "/Users/test/.npm/_cacache",
            "/Users/test/.cache/pip",
            "/Users/test/.cache/uv",
            "/Users/test/.cache/torch",
            "/Users/test/.cache/huggingface",
            "/Users/test/.gradle/caches",
            "/Users/test/.cargo/registry/cache",
            "/Users/test/Library/Caches/Homebrew",
            "/Users/test/Library/Developer/Xcode/DerivedData",
            "/Users/test/Library/Developer/CoreSimulator/Caches",
        ] {
            assert!(
                source_roots.contains(required),
                "missing source: {required}"
            );
        }
    }

    #[test]
    fn cancelled_scans_return_nothing_even_when_matches_exist() {
        let root = temp_root("cancelled-scan");
        let cache = root.join("Library/Caches/com.example.big");
        fs::create_dir_all(&cache).unwrap();
        File::create(cache.join("cache.bin"))
            .unwrap()
            .write_all(&vec![0u8; 6 * 1024 * 1024])
            .unwrap();
        write_large_file(&root.join("large.bin"));

        let live = ScanToken::never();
        assert_eq!(
            scan_large_files_from_roots(&[root.clone()], &root, 8 * 1024, false, &live).len(),
            1
        );
        assert!(!scan_cache_sources(&safe_cache_sources(&root), &live).is_empty());

        let cancelled = ScanToken::never();
        cancelled.cancel();
        assert!(
            scan_large_files_from_roots(&[root.clone()], &root, 8 * 1024, false, &cancelled)
                .is_empty()
        );
        assert!(scan_cache_sources(&safe_cache_sources(&root), &cancelled).is_empty());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancelled_footprint_walk_stops_before_measuring_files() {
        let root = temp_root("cancelled-footprint");
        fs::create_dir_all(root.join("nested/deeper")).unwrap();
        write_large_file(&root.join("nested/deeper/data.bin"));

        let live = calculate_dir_footprint_cancellable(&root, &ScanToken::never());
        assert!(live.0 > 0 && live.1 > 0);

        let cancelled = ScanToken::never();
        cancelled.cancel();
        assert_eq!(
            calculate_dir_footprint_cancellable(&root, &cancelled),
            (0, 0)
        );

        fs::remove_dir_all(root).unwrap();
    }

    fn temp_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("rustdisk-{name}-{}", std::process::id()))
    }

    fn write_large_file(path: &PathBuf) {
        File::create(path)
            .unwrap()
            .write_all(&vec![0u8; 16 * 1024])
            .unwrap();
    }
}
