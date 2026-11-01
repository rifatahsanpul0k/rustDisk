use crate::cancel::ScanToken;
use crate::scanner::calculate_dir_footprint_cancellable;
use crate::{ProjectActivity, RiskTier, ScannedItem};
use jwalk::{Parallelism, WalkDir};
use rayon::prelude::*;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const DAY_SECONDS: u64 = 86_400;
pub(crate) const DEFAULT_STALE_THRESHOLD_DAYS: u64 = 30;
pub(crate) const MIN_ARTIFACT_PHYSICAL_BYTES: u64 = 5 * 1024 * 1024;
const MAX_PROJECT_CONTEXT_ANCESTORS: usize = 3;

const IGNORED_DISCOVERY_TREES: [&str; 4] = [".git", ".Trash", "Library", "System"];
const ARTIFACT_NAMES: [&str; 19] = [
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ManifestRequirement {
    PackageJson,
    Python,
    Gradle,
    CargoOrPom,
    PackageSwift,
    Podfile,
    AnyRecognized,
}

#[derive(Clone, Debug)]
pub(crate) struct ProjectContext {
    pub(crate) root: PathBuf,
    pub(crate) ecosystem: &'static str,
    pub(crate) restore_hint: String,
    pub(crate) has_git: bool,
}

#[derive(Clone, Debug)]
struct ArtifactMatch {
    path: PathBuf,
    context: ProjectContext,
}

fn has_file(root: &Path, name: &str) -> bool {
    root.join(name).is_file()
}

fn recognized_manifest_kind(root: &Path) -> Option<&'static str> {
    if has_file(root, "Cargo.toml") {
        Some("cargo")
    } else if has_file(root, "pom.xml") {
        Some("maven")
    } else if has_file(root, "build.gradle") || has_file(root, "build.gradle.kts") {
        Some("gradle")
    } else if has_file(root, "package.json") {
        Some("node")
    } else if has_file(root, "pyproject.toml")
        || has_file(root, "requirements.txt")
        || has_file(root, "setup.py")
    {
        Some("python")
    } else if has_file(root, "Package.swift") {
        Some("swift")
    } else if has_file(root, "Podfile") {
        Some("pods")
    } else {
        None
    }
}

fn requirement_matches(kind: &str, requirement: ManifestRequirement) -> bool {
    match requirement {
        ManifestRequirement::PackageJson => kind == "node",
        ManifestRequirement::Python => kind == "python",
        ManifestRequirement::Gradle => kind == "gradle",
        ManifestRequirement::CargoOrPom => matches!(kind, "cargo" | "maven"),
        ManifestRequirement::PackageSwift => kind == "swift",
        ManifestRequirement::Podfile => kind == "pods",
        ManifestRequirement::AnyRecognized => true,
    }
}

fn context_for_manifest(root: &Path, kind: &str) -> ProjectContext {
    let restore_hint = match kind {
        "cargo" => "cargo build".to_owned(),
        "maven" => "mvn compile".to_owned(),
        "gradle" => {
            if has_file(root, "gradlew") {
                "./gradlew build".to_owned()
            } else {
                "gradle build".to_owned()
            }
        }
        "node" => "npm install".to_owned(),
        "python" => {
            if has_file(root, "requirements.txt") {
                "pip install -r requirements.txt".to_owned()
            } else {
                "pip install .".to_owned()
            }
        }
        "swift" => "swift build".to_owned(),
        "pods" => "pod install".to_owned(),
        _ => "Restore project dependencies".to_owned(),
    };

    ProjectContext {
        root: root.to_path_buf(),
        ecosystem: match kind {
            "node" => "Web & Node",
            "python" => "Python & ML",
            "gradle" | "maven" => "JVM & Build",
            "cargo" => "Rust & Systems",
            "swift" | "pods" => "Swift & Mobile",
            _ => "Web & Node",
        },
        restore_hint,
        has_git: root.join(".git").exists(),
    }
}

fn find_project_context(
    artifact_path: &Path,
    requirement: ManifestRequirement,
) -> Option<ProjectContext> {
    let mut candidate = artifact_path.parent()?;

    for _ in 0..=MAX_PROJECT_CONTEXT_ANCESTORS {
        if let Some(kind) = recognized_manifest_kind(candidate) {
            if requirement_matches(kind, requirement) {
                return Some(context_for_manifest(candidate, kind));
            }
        }
        candidate = candidate.parent()?;
    }

    None
}

pub(crate) fn classify_artifact(path: &Path) -> Option<ProjectContext> {
    let name = path.file_name()?.to_string_lossy();
    let requirement = match name.as_ref() {
        "node_modules" | ".next" | ".nuxt" | ".turbo" | ".parcel-cache" | ".vite" => {
            ManifestRequirement::PackageJson
        }
        "dist" => ManifestRequirement::AnyRecognized,
        ".venv" | "venv" | ".conda" | "__pycache__" | ".pytest_cache" | ".mypy_cache"
        | ".ruff_cache" => ManifestRequirement::Python,
        "target" => ManifestRequirement::CargoOrPom,
        "build" | ".gradle" => ManifestRequirement::Gradle,
        ".build" => ManifestRequirement::PackageSwift,
        "Pods" => ManifestRequirement::Podfile,
        _ => return None,
    };

    find_project_context(path, requirement)
}

pub(crate) fn is_ignored_discovery_name(name: &str) -> bool {
    IGNORED_DISCOVERY_TREES.contains(&name)
}

fn is_ignored_activity_name(name: &str) -> bool {
    matches!(name, ".git" | ".Trash") || is_artifact_name(name)
}

pub(crate) fn is_artifact_name(name: &str) -> bool {
    ARTIFACT_NAMES.contains(&name)
}

fn discover_artifact_directories(root_path: &Path, token: &ScanToken) -> Vec<ArtifactMatch> {
    let walk_token = token.clone();
    let walker = WalkDir::new(root_path)
        .skip_hidden(false)
        .follow_links(false)
        .process_read_dir(move |_, _, _, children| {
            if walk_token.is_cancelled() {
                children.clear();
                return;
            }
            for child in children.iter_mut() {
                if let Ok(entry) = child {
                    let name = entry.file_name.to_string_lossy();
                    if is_ignored_discovery_name(&name) {
                        entry.read_children_path = None;
                    } else if is_artifact_name(&name) && classify_artifact(&entry.path()).is_some()
                    {
                        // Measure this artifact as a single unit. Its nested dependency trees
                        // are included in its footprint and must not become separate entries.
                        entry.read_children_path = None;
                    }
                }
            }
        });

    walker
        .into_iter()
        .flatten()
        .take_while(|_| !token.is_cancelled())
        .filter_map(|entry| {
            if !entry.file_type().is_dir() {
                return None;
            }
            let context = classify_artifact(&entry.path())?;
            Some(ArtifactMatch {
                path: entry.path(),
                context,
            })
        })
        .collect()
}

fn most_recent_source_modification(project_root: &Path, token: &ScanToken) -> SystemTime {
    let mut latest_modification = SystemTime::UNIX_EPOCH;
    let walk_token = token.clone();
    // Serial for the same reason as `calculate_dir_footprint_cancellable`: this
    // runs inside a rayon `par_iter` closure.
    let walker = WalkDir::new(project_root)
        .parallelism(Parallelism::Serial)
        .max_depth(3)
        .skip_hidden(false)
        .follow_links(false)
        .process_read_dir(move |_, _, _, children| {
            if walk_token.is_cancelled() {
                children.clear();
                return;
            }
            for child in children.iter_mut() {
                if let Ok(entry) = child {
                    let name = entry.file_name.to_string_lossy();
                    if is_ignored_activity_name(&name) {
                        entry.read_children_path = None;
                    }
                }
            }
        });

    for entry in walker.into_iter().flatten() {
        if token.is_cancelled() {
            break;
        }
        let name = entry.file_name.to_string_lossy();
        if !entry.file_type().is_file() || name == ".DS_Store" {
            continue;
        }

        if let Ok(modified) =
            fs::symlink_metadata(entry.path()).and_then(|metadata| metadata.modified())
        {
            if modified > latest_modification {
                latest_modification = modified;
            }
        }
    }

    latest_modification
}

pub(crate) fn check_project_activity(
    project_root: &Path,
    stale_threshold_days: u64,
    token: &ScanToken,
) -> (ProjectActivity, u64) {
    let threshold = if stale_threshold_days == 0 {
        DEFAULT_STALE_THRESHOLD_DAYS
    } else {
        stale_threshold_days
    };
    let latest_modification = most_recent_source_modification(project_root, token);
    let elapsed_days = SystemTime::now()
        .duration_since(latest_modification)
        .unwrap_or(Duration::ZERO)
        .as_secs()
        / DAY_SECONDS;

    if elapsed_days >= threshold {
        (ProjectActivity::Stale, elapsed_days)
    } else {
        (ProjectActivity::Active, elapsed_days)
    }
}

/// Finds manifest-backed project dependency/build directories and classifies source activity.
#[uniffi::export]
pub fn scan_project_artifacts(root_path: String, stale_threshold_days: u64) -> Vec<ScannedItem> {
    let token = ScanToken::begin();
    scan_project_artifacts_impl(&root_path, stale_threshold_days, &token)
}

pub(crate) fn build_project_scanned_item(
    artifact_path: &Path,
    context: &ProjectContext,
    stale_threshold_days: u64,
    token: &ScanToken,
) -> Option<ScannedItem> {
    let (physical_bytes, logical_bytes) = calculate_dir_footprint_cancellable(artifact_path, token);
    if physical_bytes < MIN_ARTIFACT_PHYSICAL_BYTES {
        return None;
    }

    let (activity, days_since_modified) =
        check_project_activity(&context.root, stale_threshold_days, token);
    if token.is_cancelled() {
        return None;
    }
    let project_name = context
        .root
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Unknown Project".to_owned());
    let artifact_name = artifact_path.file_name()?.to_string_lossy().into_owned();
    let path = artifact_path.to_string_lossy().into_owned();
    let project_root = context.root.to_string_lossy().into_owned();

    Some(ScannedItem {
        id: path.clone(),
        name: format!("{project_name} ({artifact_name})"),
        path,
        physical_bytes,
        logical_bytes,
        category: artifact_name,
        risk: RiskTier::Rebuildable,
        activity,
        days_since_modified,
        ecosystem: context.ecosystem.to_owned(),
        project_root,
        restore_hint: context.restore_hint.clone(),
        has_git: context.has_git,
    })
}

fn scan_project_artifacts_impl(
    root_path: &str,
    stale_threshold_days: u64,
    token: &ScanToken,
) -> Vec<ScannedItem> {
    crate::configure_scan_thread_pool();
    crate::thermal::apply_current_thread_thermal_policy();
    let found_dirs = discover_artifact_directories(Path::new(root_path), token);
    let mut items: Vec<ScannedItem> = found_dirs
        .par_iter()
        .filter_map(|artifact| {
            if token.is_cancelled() {
                return None;
            }
            build_project_scanned_item(
                &artifact.path,
                &artifact.context,
                stale_threshold_days,
                token,
            )
        })
        .collect();

    if token.is_cancelled() {
        return Vec::new();
    }
    items.sort_by(|left, right| right.physical_bytes.cmp(&left.physical_bytes));
    items
}

#[cfg(test)]
mod tests {
    use super::{scan_project_artifacts, scan_project_artifacts_impl};
    use crate::cancel::ScanToken;
    use crate::cleaner::purge_items;
    use crate::{DeletionMode, ProjectActivity};
    use filetime::{set_file_mtime, FileTime};
    use std::collections::HashSet;
    use std::fs::{self, File};
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime};

    const ARTIFACT_BYTES: usize = 6 * 1024 * 1024;

    #[test]
    fn nested_artifacts_are_pruned_and_counted_once() {
        let root = temp_root("nested-artifacts");
        let artifact = root.join("node_modules");
        fs::create_dir_all(artifact.join("pkg_a/node_modules")).unwrap();
        write_bytes(&root.join("package.json"), b"{}");
        write_bytes(&artifact.join("root.bin"), &vec![0u8; ARTIFACT_BYTES]);
        write_bytes(
            &artifact.join("pkg_a/node_modules/nested.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );

        let items = scan_project_artifacts(root.to_string_lossy().into_owned(), 30);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].category, "node_modules");
        assert_eq!(items[0].ecosystem, "Web & Node");
        assert!(items[0].physical_bytes >= (ARTIFACT_BYTES * 2) as u64);

        remove_root(root);
    }

    #[test]
    fn manifest_disambiguation_ignores_arbitrary_target_and_build_directories() {
        let root = temp_root("manifest-disambiguation");
        let cargo_project = root.join("cargo-project");
        let gradle_project = root.join("gradle-project");
        let arbitrary = root.join("arbitrary");
        for path in [&cargo_project, &gradle_project, &arbitrary] {
            fs::create_dir_all(path).unwrap();
        }
        write_bytes(
            &cargo_project.join("Cargo.toml"),
            b"[package]\nname='test'\nversion='0.1.0'\n",
        );
        write_bytes(&gradle_project.join("build.gradle"), b"plugins {}\n");
        write_bytes(
            &cargo_project.join("target/artifact.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );
        write_bytes(
            &gradle_project.join("build/artifact.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );
        write_bytes(
            &arbitrary.join("target/artifact.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );
        write_bytes(
            &arbitrary.join("build/artifact.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );

        let items = scan_project_artifacts(root.to_string_lossy().into_owned(), 30);
        let paths: HashSet<_> = items.iter().map(|item| item.path.as_str()).collect();
        assert!(paths.contains(cargo_project.join("target").to_string_lossy().as_ref()));
        assert!(paths.contains(gradle_project.join("build").to_string_lossy().as_ref()));
        assert!(!paths.contains(arbitrary.join("target").to_string_lossy().as_ref()));
        assert!(!paths.contains(arbitrary.join("build").to_string_lossy().as_ref()));

        remove_root(root);
    }

    #[test]
    fn source_activity_ignores_old_artifacts_and_respects_threshold() {
        let root = temp_root("activity");
        let active = root.join("active");
        let stale = root.join("stale");
        fs::create_dir_all(active.join("node_modules")).unwrap();
        fs::create_dir_all(stale.join("node_modules")).unwrap();
        write_bytes(&active.join("package.json"), b"{}");
        write_bytes(&stale.join("package.json"), b"{}");
        write_bytes(
            &active.join("node_modules/dependency.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );
        write_bytes(
            &stale.join("node_modules/dependency.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );
        let old = FileTime::from_system_time(SystemTime::now() - Duration::from_secs(45 * 86_400));
        set_file_mtime(stale.join("package.json"), old).unwrap();
        set_file_mtime(stale.join("node_modules/dependency.bin"), old).unwrap();

        let active_items = scan_project_artifacts(root.to_string_lossy().into_owned(), 30);
        let active_item = active_items
            .iter()
            .find(|item| item.project_root == active.to_string_lossy())
            .unwrap();
        let stale_item = active_items
            .iter()
            .find(|item| item.project_root == stale.to_string_lossy())
            .unwrap();
        assert_eq!(active_item.activity, ProjectActivity::Active);
        assert_eq!(stale_item.activity, ProjectActivity::Stale);

        let borderline = root.join("borderline");
        fs::create_dir_all(borderline.join("node_modules")).unwrap();
        write_bytes(&borderline.join("package.json"), b"{}");
        write_bytes(
            &borderline.join("node_modules/dependency.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );
        let borderline_time =
            FileTime::from_system_time(SystemTime::now() - Duration::from_secs(20 * 86_400));
        set_file_mtime(borderline.join("package.json"), borderline_time).unwrap();
        let fourteen_day = scan_project_artifacts(root.to_string_lossy().into_owned(), 14);
        let sixty_day = scan_project_artifacts(root.to_string_lossy().into_owned(), 60);
        assert_eq!(
            fourteen_day
                .iter()
                .find(|item| item.project_root == borderline.to_string_lossy())
                .unwrap()
                .activity,
            ProjectActivity::Stale
        );
        assert_eq!(
            sixty_day
                .iter()
                .find(|item| item.project_root == borderline.to_string_lossy())
                .unwrap()
                .activity,
            ProjectActivity::Active
        );

        remove_root(root);
    }

    #[test]
    fn project_artifact_cleanup_leaves_sources_and_git_untouched() {
        let root = temp_root("cleanup-integration");
        let artifact = root.join("target");
        fs::create_dir_all(artifact.clone()).unwrap();
        fs::create_dir_all(root.join(".git")).unwrap();
        write_bytes(
            &root.join("Cargo.toml"),
            b"[package]\nname='test'\nversion='0.1.0'\n",
        );
        write_bytes(&root.join("src.rs"), b"fn main() {}\n");
        write_bytes(&root.join(".git/HEAD"), b"ref: refs/heads/main\n");
        write_bytes(&artifact.join("artifact.bin"), &vec![0u8; ARTIFACT_BYTES]);

        let items = scan_project_artifacts(root.to_string_lossy().into_owned(), 30);
        assert_eq!(items.len(), 1);
        let report = purge_items(vec![items[0].path.clone()], DeletionMode::PermanentDelete);
        assert!(report.permanently_freed_physical_bytes > 0);
        assert!(report.deleted_items_count >= 1);
        assert!(report.errors.is_empty());
        assert!(!artifact.exists());
        assert!(root.join("Cargo.toml").exists());
        assert!(root.join("src.rs").exists());
        assert!(root.join(".git/HEAD").exists());

        remove_root(root);
    }

    #[test]
    fn cancelled_project_scan_returns_nothing() {
        let root = temp_root("cancelled-projects");
        write_bytes(&root.join("package.json"), b"{}");
        write_bytes(
            &root.join("node_modules/dep.bin"),
            &vec![0u8; ARTIFACT_BYTES],
        );
        let root_path = root.to_string_lossy().into_owned();

        let live = scan_project_artifacts_impl(&root_path, 30, &ScanToken::never());
        assert_eq!(live.len(), 1);

        let cancelled = ScanToken::never();
        cancelled.cancel();
        assert!(scan_project_artifacts_impl(&root_path, 30, &cancelled).is_empty());

        remove_root(root);
    }

    fn write_bytes(path: &Path, bytes: &[u8]) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        File::create(path).unwrap().write_all(bytes).unwrap();
    }

    fn temp_root(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("rustdisk-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        path
    }

    fn remove_root(root: PathBuf) {
        fs::remove_dir_all(root).unwrap();
    }
}
