use crate::cancel::ScanToken;
use crate::duplicates::{FileCandidate, SystemRoots};
use crate::{DiskOverview, FullAuditOptions, FullAuditReport, ProjectActivity, ScannedItem};
use jwalk::WalkDir;
use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

fn empty_report(disk_overview: DiskOverview) -> FullAuditReport {
    FullAuditReport {
        safe_caches: Vec::new(),
        project_artifacts: Vec::new(),
        terminal_packages: Vec::new(),
        large_files: Vec::new(),
        duplicate_groups: Vec::new(),
        disk_overview,
    }
}

pub(crate) fn scan_full_audit_impl(
    options: FullAuditOptions,
    token: &ScanToken,
) -> FullAuditReport {
    crate::configure_scan_thread_pool();
    crate::thermal::apply_current_thread_thermal_policy();
    let disk_overview = crate::telemetry::get_disk_overview();

    let root_path_buf = PathBuf::from(&options.root_path);
    let stale_threshold = if options.stale_threshold_days == 0 {
        crate::projects::DEFAULT_STALE_THRESHOLD_DAYS
    } else {
        options.stale_threshold_days
    };
    let duplicate_min_bytes = if options.duplicate_min_size_bytes == 0 {
        crate::duplicates::DEFAULT_MIN_SIZE_BYTES
    } else {
        options.duplicate_min_size_bytes
    };
    let large_threshold = options.large_file_threshold_bytes;
    let include_dev_caches = options.include_dev_caches_in_large_files;

    // 1. Collect targeted Safe Caches & Terminal Packages
    let safe_caches = crate::scanner::scan_safe_caches_with_token(&root_path_buf, token);
    if token.is_cancelled() {
        return empty_report(disk_overview);
    }

    let terminal_packages =
        crate::packages::scan_terminal_packages_with_token(&root_path_buf, token);
    if token.is_cancelled() {
        return empty_report(disk_overview);
    }

    // 2. Perform ONE unified walk over root_path (plus /opt/homebrew if applicable)
    let roots = crate::scanner::large_file_roots(&root_path_buf);

    let mut project_artifacts = Vec::new();
    let mut large_files = Vec::new();
    let mut duplicate_candidates: Vec<FileCandidate> = Vec::new();
    let mut seen_project_paths = HashSet::new();
    let mut seen_large_file_inodes = HashSet::new();
    let mut seen_duplicate_inodes = HashSet::new();
    let mut walk_counter = 0u32;

    for root in &roots {
        if token.is_cancelled() {
            return empty_report(disk_overview);
        }
        if !root.exists()
            || crate::scanner::should_skip_large_file_path(root)
            || crate::scanner::is_macos_bundle(root)
        {
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
                for entry in children.iter_mut().flatten() {
                    let path = entry.path();
                    if entry.file_type().is_dir() {
                        let name = entry.file_name.to_string_lossy();
                        if crate::scanner::should_skip_large_file_path(&path)
                            || crate::scanner::is_macos_bundle(&path)
                            || crate::projects::is_ignored_discovery_name(&name)
                        {
                            entry.read_children_path = None;
                        } else if crate::projects::is_artifact_name(&name)
                            && crate::projects::classify_artifact(&path).is_some()
                        {
                            // Prune descent: this is a manifest-verified project artifact
                            entry.read_children_path = None;
                        } else if !include_dev_caches
                            && crate::scanner::is_known_dev_cache_or_runtime(&path)
                        {
                            entry.read_children_path = None;
                        }
                    }
                }
            });

        for entry in walker.into_iter().flatten() {
            if token.is_cancelled() {
                return empty_report(disk_overview);
            }
            crate::thermal::thermal_pace_walk(&mut walk_counter);
            let path = entry.path();

            if entry.file_type().is_dir() {
                let name = entry.file_name.to_string_lossy();
                if crate::projects::is_artifact_name(&name) {
                    if let Some(context) = crate::projects::classify_artifact(&path) {
                        if seen_project_paths.insert(path.clone()) {
                            if let Some(item) = crate::projects::build_project_scanned_item(
                                &path,
                                &context,
                                stale_threshold,
                                token,
                            ) {
                                project_artifacts.push(item);
                            }
                        }
                    }
                }
                continue;
            }

            if !entry.file_type().is_file() || crate::scanner::should_skip_large_file_path(&path) {
                continue;
            }

            let Some((physical_bytes, logical_bytes)) =
                crate::scanner::calculate_file_footprint(&path)
            else {
                continue;
            };

            let metadata = fs::symlink_metadata(&path).ok();
            let (device, inode, modified) = match &metadata {
                Some(meta) => (
                    meta.dev(),
                    meta.ino(),
                    meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                ),
                None => (0, 0, SystemTime::UNIX_EPOCH),
            };

            // Tab 4 (Large Files)
            if physical_bytes >= large_threshold
                && (include_dev_caches || !crate::scanner::is_known_dev_cache_or_runtime(&path))
                && seen_large_file_inodes.insert((device, inode))
            {
                let category = crate::scanner::category_for_large_file(&path);
                let risk = crate::scanner::risk_for_large_file(&path, &root_path_buf, category);
                let name = path
                    .file_name()
                    .map(|v| v.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.to_string_lossy().into_owned());
                let path_str = path.to_string_lossy().into_owned();
                let days = SystemTime::now()
                    .duration_since(modified)
                    .unwrap_or(Duration::ZERO)
                    .as_secs()
                    / 86_400;

                large_files.push(ScannedItem {
                    id: path_str.clone(),
                    name,
                    path: path_str,
                    physical_bytes,
                    logical_bytes,
                    category: category.to_owned(),
                    risk,
                    activity: ProjectActivity::NotProject,
                    days_since_modified: days,
                    ecosystem: String::new(),
                    project_root: String::new(),
                    restore_hint: String::new(),
                    has_git: false,
                });
            }

            // Tab 5 (Duplicates Candidate)
            if physical_bytes >= duplicate_min_bytes
                && !crate::duplicates::is_protected_path(&path)
                && !crate::duplicates::is_bundle(&path)
                && seen_duplicate_inodes.insert((device, inode))
            {
                duplicate_candidates.push(FileCandidate {
                    path: path.clone(),
                    physical_bytes,
                    logical_bytes,
                    modified,
                    device,
                    inode,
                });
            }
        }
    }

    if token.is_cancelled() {
        return empty_report(disk_overview);
    }

    large_files.sort_by_key(|left| std::cmp::Reverse(left.physical_bytes));
    project_artifacts.sort_by_key(|left| std::cmp::Reverse(left.physical_bytes));

    // 3. Run Duplicate Stage 2, Stage 3, folder rollup, and package duplicates
    let system_roots = SystemRoots::for_scan_root(&root_path_buf);
    let duplicate_groups = crate::duplicates::process_duplicate_candidates(
        &root_path_buf,
        duplicate_candidates,
        &system_roots,
        token,
    );

    if token.is_cancelled() {
        return empty_report(disk_overview);
    }

    FullAuditReport {
        safe_caches,
        project_artifacts,
        terminal_packages,
        large_files,
        duplicate_groups,
        disk_overview,
    }
}

/// Executes a single-pass full audit over the specified root directory.
#[uniffi::export]
pub fn scan_full_audit(options: FullAuditOptions) -> FullAuditReport {
    let token = ScanToken::begin();
    scan_full_audit_impl(options, &token)
}

#[cfg(test)]
mod tests {
    use super::*;
    use filetime::{set_file_mtime, FileTime};

    #[test]
    fn unified_single_pass_parity_and_pruning() {
        let temp_dir = std::env::temp_dir().join(format!(
            "rustdisk_unified_test_{}_{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).unwrap();

        // 1. Safe cache in .npm/_cacache
        let cache_dir = temp_dir.join(".npm/_cacache");
        fs::create_dir_all(&cache_dir).unwrap();
        fs::write(cache_dir.join("cache.dat"), vec![0xCC; 1024]).unwrap();

        // 2. Stale node_modules project
        let project_dir = temp_dir.join("my_web_project");
        let nm_dir = project_dir.join("node_modules");
        let src_dir = project_dir.join("src");
        fs::create_dir_all(&nm_dir).unwrap();
        fs::create_dir_all(&src_dir).unwrap();

        fs::write(project_dir.join("package.json"), "{}").unwrap();
        let old_src = src_dir.join("index.js");
        fs::write(&old_src, "console.log('hi');").unwrap();
        // Set modification time to 45 days ago
        let old_time = FileTime::from_unix_time(
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64
                - 45 * 86400,
            0,
        );
        set_file_mtime(&old_src, old_time).unwrap();

        // Make node_modules exceed MIN_ARTIFACT_PHYSICAL_BYTES (5 MiB)
        let nm_file = nm_dir.join("payload.dat");
        let payload = vec![0xAA; 5 * 1024 * 1024 + 512 * 1024]; // 5.5 MiB
        fs::write(&nm_file, &payload).unwrap();

        // 3. Large .dmg file
        let dmg_file = temp_dir.join("test_installer.dmg");
        let dmg_payload = vec![0xBB; 2 * 1024 * 1024]; // 2 MiB
        fs::write(&dmg_file, &dmg_payload).unwrap();

        // 4. Duplicate files
        let dup1 = temp_dir.join("duplicate_copy1.bin");
        let dup2 = temp_dir.join("duplicate_copy2.bin");
        let dup_payload = vec![0xDD; 64 * 1024]; // 64 KiB
        fs::write(&dup1, &dup_payload).unwrap();
        fs::write(&dup2, &dup_payload).unwrap();

        let options = FullAuditOptions {
            root_path: temp_dir.to_string_lossy().into_owned(),
            stale_threshold_days: 30,
            large_file_threshold_bytes: 1024 * 1024, // 1 MiB threshold
            include_dev_caches_in_large_files: false,
            duplicate_min_size_bytes: 32 * 1024, // 32 KiB threshold
        };

        let token = ScanToken::begin();

        // Call individual scanners
        let caches_individual = crate::scanner::scan_safe_caches(options.root_path.clone());
        let projects_individual =
            crate::projects::scan_project_artifacts(options.root_path.clone(), 30);
        let large_individual = crate::scanner::scan_large_files_with_options(
            options.root_path.clone(),
            options.large_file_threshold_bytes,
            false,
        );
        let duplicates_individual = crate::duplicates::scan_duplicates(
            options.root_path.clone(),
            options.duplicate_min_size_bytes,
        );

        // Call unified scan
        let report = scan_full_audit_impl(options, &token);

        // Parity assertions
        assert_eq!(report.safe_caches.len(), caches_individual.len());
        assert_eq!(report.project_artifacts.len(), projects_individual.len());
        assert_eq!(report.large_files.len(), large_individual.len());
        assert_eq!(report.duplicate_groups.len(), duplicates_individual.len());

        // Pruning assertions: node_modules internal file must NOT be in large files or duplicates
        assert!(
            !report
                .large_files
                .iter()
                .any(|item| item.path.contains("node_modules")),
            "node_modules contents must be pruned from large files"
        );
        assert!(
            !report.duplicate_groups.iter().any(|group| {
                group
                    .members
                    .iter()
                    .any(|m| m.path.contains("node_modules"))
            }),
            "node_modules contents must be pruned from duplicates"
        );

        // Found items verification
        assert!(report
            .large_files
            .iter()
            .any(|item| item.name == "test_installer.dmg"));
        assert!(report
            .project_artifacts
            .iter()
            .any(|item| item.category == "node_modules"));
        assert_eq!(report.duplicate_groups.len(), 1);

        let _ = fs::remove_dir_all(&temp_dir);
    }
}
