use crate::scanner::{calculate_dir_footprint, calculate_file_footprint};
use crate::{CleanupReport, DeletionMode, RustDiskError};
use std::collections::HashSet;
use std::ffi::CStr;
use std::fs;
use std::io::{Error, ErrorKind};
use std::path::{Component, Path, PathBuf};

/// Locations that are never deleted, nor anything beneath them. Everything
/// here is lowercase because the check lowercases paths first: default APFS is
/// case-insensitive, so `/system` and `/System` are the same directory.
const PROTECTED_ROOTS: [&str; 6] = [
    "/system",
    "/bin",
    "/sbin",
    "/usr",
    "/applications",
    "/library",
];
const OPT_ROOT: &str = "/opt";
/// The only part of `/opt` that may be cleaned, and only below this folder.
const HOMEBREW_ROOT: &str = "/opt/homebrew";
const USERS_ROOT: &str = "/users";
const PROTECTED_COMPONENTS: [&str; 4] = [".git", ".ssh", ".gnupg", ".aws"];
const PROTECTED_FILE_NAME: &str = "docker.raw";

/// The deletion guardrails ("System Armor").
///
/// A path must pass twice: once as written, and once after `fs::canonicalize`
/// resolves symlinks and `..`. The second pass stops a symlink in an allowed
/// folder from pointing a delete at a protected one.
pub(crate) struct SystemArmor {
    /// Lowercase absolute home directories, as written and as resolved.
    homes: Vec<PathBuf>,
}

impl SystemArmor {
    pub(crate) fn for_current_user() -> Self {
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Some(home) = std::env::var_os("HOME") {
            candidates.push(PathBuf::from(home));
        }
        // $HOME can be unset or wrong in a GUI process, so also ask the account database.
        candidates.extend(passwd_home_dir());
        Self::with_homes(candidates)
    }

    fn with_homes(homes: impl IntoIterator<Item = impl Into<PathBuf>>) -> Self {
        let mut resolved = Vec::new();
        for home in homes {
            let home: PathBuf = home.into();
            if !home.is_absolute() {
                continue;
            }
            if let Ok(canonical) = fs::canonicalize(&home) {
                resolved.push(lowercase_path(&canonical));
            }
            resolved.push(lowercase_path(&home));
        }
        resolved.sort();
        resolved.dedup();
        Self { homes: resolved }
    }

    /// Returns `Err(reason)` when `path` must not be deleted.
    pub(crate) fn check(&self, path: &Path) -> Result<(), String> {
        if !path.is_absolute() {
            return Err("path is not absolute".to_owned());
        }
        if path
            .components()
            .any(|component| matches!(component, Component::ParentDir))
        {
            return Err("path contains '..'".to_owned());
        }
        if let Some(reason) = self.blocked_reason(path) {
            return Err(reason);
        }

        match fs::canonicalize(path) {
            Ok(resolved) => match self.blocked_reason(&resolved) {
                Some(reason) => Err(format!("resolves to {}: {reason}", resolved.display())),
                None => Ok(()),
            },
            // Nothing exists there, so there is nothing to protect. The caller
            // reports the missing path.
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
            // Fail closed: a path that cannot be resolved cannot be proven safe.
            Err(error) => Err(format!("path could not be resolved ({error})")),
        }
    }

    fn blocked_reason(&self, path: &Path) -> Option<String> {
        let lowered = lowercase_path(path);
        let path = lowered.as_path();

        if path == Path::new("/") {
            return Some("the filesystem root is protected".to_owned());
        }
        if PROTECTED_ROOTS
            .iter()
            .any(|root| path.starts_with(Path::new(root)))
        {
            return Some("system and application locations are protected".to_owned());
        }
        if path.starts_with(OPT_ROOT) {
            let inside_homebrew =
                path.starts_with(HOMEBREW_ROOT) && path != Path::new(HOMEBREW_ROOT);
            if !inside_homebrew {
                return Some("only items inside /opt/homebrew can be deleted".to_owned());
            }
        }
        // `/Users` itself and every account's home folder, so a failed path
        // resolution can never turn into deleting a whole home directory.
        if path == Path::new(USERS_ROOT) || path.parent() == Some(Path::new(USERS_ROOT)) {
            return Some("home folders are protected".to_owned());
        }
        if self
            .homes
            .iter()
            .any(|home| path == home.as_path() || home.starts_with(path))
        {
            return Some("the home folder is protected".to_owned());
        }
        if path.components().any(|component| {
            PROTECTED_COMPONENTS.contains(&component.as_os_str().to_string_lossy().as_ref())
        }) {
            return Some("credentials and repository metadata are protected".to_owned());
        }
        if path
            .file_name()
            .is_some_and(|name| name.to_string_lossy() == PROTECTED_FILE_NAME)
        {
            return Some("the Docker virtual disk is only managed through Docker".to_owned());
        }
        None
    }
}

fn lowercase_path(path: &Path) -> PathBuf {
    PathBuf::from(path.to_string_lossy().to_lowercase())
}

pub(crate) fn passwd_home_dir() -> Option<PathBuf> {
    let mut buffer = vec![0 as libc::c_char; 4096];
    // SAFETY: `passwd` is plain data that getpwuid_r fully initializes on
    // success, `buffer` outlives every use of the returned pointers, and
    // `pw_dir` is only read after checking the call succeeded and it is non-null.
    unsafe {
        let mut passwd: libc::passwd = std::mem::zeroed();
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        let status = libc::getpwuid_r(
            libc::getuid(),
            &mut passwd,
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut result,
        );
        if status != 0 || result.is_null() || passwd.pw_dir.is_null() {
            return None;
        }
        CStr::from_ptr(passwd.pw_dir)
            .to_str()
            .ok()
            .map(PathBuf::from)
    }
}

fn measured_bytes(path: &Path) -> u64 {
    if path.is_dir() {
        calculate_dir_footprint(path).0
    } else {
        calculate_file_footprint(path)
            .map(|(physical, _)| physical)
            .unwrap_or(0)
    }
}

fn is_locked_error(error: &Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::PermissionDenied | ErrorKind::WouldBlock
    ) || matches!(error.raw_os_error(), Some(1 | 13))
}

fn is_locked_message(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    message.contains("permission denied")
        || message.contains("operation not permitted")
        || message.contains("os error 1")
        || message.contains("os error 13")
        || message.contains("eperm")
        || message.contains("eacces")
}

fn record_error(report: &mut CleanupReport, path: &Path, error: impl std::fmt::Display) {
    let message = format!("{}: {}", path.display(), error);
    if is_locked_message(&message) {
        report.skipped_locked_count = report.skipped_locked_count.saturating_add(1);
    } else {
        report.errors.push(message);
    }
}

fn record_io_error(report: &mut CleanupReport, path: &Path, error: &Error) {
    if is_locked_error(error) {
        report.skipped_locked_count = report.skipped_locked_count.saturating_add(1);
    } else if error.kind() != ErrorKind::DirectoryNotEmpty {
        report.errors.push(format!("{}: {}", path.display(), error));
    }
}

fn path_exists(path: &Path) -> bool {
    match fs::symlink_metadata(path) {
        Ok(_) => true,
        Err(error) => error.kind() != ErrorKind::NotFound,
    }
}

fn remove_dir_resilient(path: &Path, report: &mut CleanupReport) {
    if !path_exists(path) {
        report.deleted_items_count = report.deleted_items_count.saturating_add(1);
        return;
    }

    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) => {
            record_io_error(report, path, &error);
            return;
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                record_io_error(report, path, &error);
                continue;
            }
        };
        let child = entry.path();
        let child_type = match fs::symlink_metadata(&child) {
            Ok(metadata) => metadata.file_type(),
            Err(error) => {
                record_io_error(report, &child, &error);
                continue;
            }
        };

        if child_type.is_dir() && !child_type.is_symlink() {
            remove_dir_resilient(&child, report);
        } else {
            match fs::remove_file(&child) {
                Ok(()) => report.deleted_items_count = report.deleted_items_count.saturating_add(1),
                Err(error) => record_io_error(report, &child, &error),
            }
        }
    }

    match fs::remove_dir(path) {
        Ok(()) => report.deleted_items_count = report.deleted_items_count.saturating_add(1),
        Err(error) => record_io_error(report, path, &error),
    }
}

/// Moves one item to the user's Trash through the system Trash.
type MoveToTrash<'a> = &'a dyn Fn(&Path) -> Result<(), String>;

fn system_trash(path: &Path) -> Result<(), String> {
    trash::delete(path).map_err(|error| error.to_string())
}

fn remove_one(
    path: &Path,
    mode: DeletionMode,
    report: &mut CleanupReport,
    move_to_trash: MoveToTrash,
) {
    match mode {
        DeletionMode::MoveToTrash => match move_to_trash(path) {
            Ok(()) => report.deleted_items_count = report.deleted_items_count.saturating_add(1),
            Err(error) => record_error(report, path, error),
        },
        DeletionMode::PermanentDelete if path.is_dir() => match fs::remove_dir_all(path) {
            Ok(()) => report.deleted_items_count = report.deleted_items_count.saturating_add(1),
            Err(_) => remove_dir_resilient(path, report),
        },
        DeletionMode::PermanentDelete => match fs::remove_file(path) {
            Ok(()) => report.deleted_items_count = report.deleted_items_count.saturating_add(1),
            Err(error) => record_io_error(report, path, &error),
        },
    }
}

/// Deletes as many requested items as possible and reports locked paths instead of aborting.
///
/// Moving to the Trash keeps the data on the same APFS volume, so those bytes
/// are reported as `trashed_physical_bytes` and never as freed space. Only a
/// permanent delete reports `permanently_freed_physical_bytes`.
#[uniffi::export]
pub fn purge_items(paths: Vec<String>, mode: DeletionMode) -> CleanupReport {
    purge_with(paths, mode, &SystemArmor::for_current_user(), &system_trash)
}

fn purge_with(
    paths: Vec<String>,
    mode: DeletionMode,
    armor: &SystemArmor,
    move_to_trash: MoveToTrash,
) -> CleanupReport {
    let mut report = CleanupReport {
        trashed_physical_bytes: 0,
        permanently_freed_physical_bytes: 0,
        deleted_items_count: 0,
        skipped_locked_count: 0,
        errors: Vec::new(),
    };
    let mut seen = HashSet::new();

    for path in paths {
        if !seen.insert(path.clone()) {
            continue;
        }

        let target = Path::new(&path);
        if let Err(reason) = armor.check(target) {
            report
                .errors
                .push(format!("Blocked by System Armor: {path} ({reason})"));
            continue;
        }
        if !target.exists() {
            report.errors.push(format!("Path no longer exists: {path}"));
            continue;
        }

        let before = measured_bytes(target);
        remove_one(target, mode, &mut report, move_to_trash);
        let after = if path_exists(target) {
            measured_bytes(target)
        } else {
            0
        };
        let removed = before.saturating_sub(after);
        let bucket = match mode {
            DeletionMode::MoveToTrash => &mut report.trashed_physical_bytes,
            DeletionMode::PermanentDelete => &mut report.permanently_freed_physical_bytes,
        };
        *bucket = bucket.saturating_add(removed);
    }

    report
}

/// Compatibility wrapper for callers that delete one item at a time. Returns the
/// physical bytes permanently freed, which is always 0 when moving to the Trash.
#[uniffi::export]
pub fn delete_item(path: String, mode: DeletionMode) -> Result<u64, RustDiskError> {
    let report = purge_items(vec![path], mode);
    if let Some(error) = report.errors.first() {
        return Err(RustDiskError::message(error.clone()));
    }
    if report.skipped_locked_count > 0 {
        return Err(RustDiskError::message(
            "Item was locked and could not be deleted.",
        ));
    }
    Ok(report.permanently_freed_physical_bytes)
}

#[cfg(test)]
mod tests {
    use super::{purge_items, purge_with, SystemArmor};
    use crate::DeletionMode;
    use std::fs::{self, File};
    use std::io::Write;
    use std::os::unix::fs::symlink;
    use std::path::{Path, PathBuf};

    /// An armor for a made-up user, so the tests do not depend on the real home folder.
    fn armor() -> SystemArmor {
        SystemArmor::with_homes(["/Users/test"])
    }

    fn blocked(path: &str) -> bool {
        armor().check(Path::new(path)).is_err()
    }

    #[test]
    fn system_armor_blocks_sensitive_paths() {
        assert!(blocked("/System/Library"));
        assert!(blocked("/Users/test/.ssh"));
        assert!(blocked("/Users/test/.gnupg/pubring.kbx"));
        assert!(blocked("/Users/test/.aws/credentials"));
        assert!(blocked("/Users/test/project/.git"));
        assert!(blocked("/Users/test/Docker.raw"));
        assert!(blocked("/"));
        assert!(blocked("relative/path"));
        assert!(!blocked("/Users/test/Library/Caches/foo"));
    }

    #[test]
    fn system_armor_ignores_letter_case() {
        assert!(blocked("/system/library"));
        assert!(blocked("/SYSTEM"));
        assert!(blocked("/applications/Safari.app"));
        assert!(blocked("/LIBRARY/Caches/foo"));
        assert!(blocked("/USR/local/bin"));
        assert!(blocked("/OPT/other"));
        assert!(blocked("/users/TEST"));
        assert!(blocked("/Users/test/.SSH/id_rsa"));
        assert!(blocked("/Users/test/.Git"));
        assert!(blocked("/Users/test/DOCKER.RAW"));
        assert!(blocked("/Users/test/library/containers/x/docker.raw"));
    }

    #[test]
    fn system_armor_blocks_the_expanded_roots_but_not_user_data_below_them() {
        for path in [
            "/Applications",
            "/Applications/Xcode.app",
            "/Library",
            "/Library/Caches/com.example",
            "/Library/Apple/usr",
            "/usr",
            "/usr/local/Cellar/foo",
            "/usr/bin/env",
            "/opt",
            "/opt/local/bin",
            "/opt/miniconda3",
            "/opt/homebrew",
        ] {
            assert!(blocked(path), "{path} must be blocked");
        }

        for path in [
            "/opt/homebrew/Cellar/python@3.12/3.12.1",
            "/opt/homebrew/Caskroom/foo",
            "/Users/test/Library/Caches/com.example",
            "/Users/test/Library/Developer/Xcode/DerivedData",
            "/Users/test/project/node_modules",
            "/Users/test/Downloads/installer.dmg",
            // Name lookalikes are different directories, not the protected ones.
            "/Systems/foo",
            "/Librarian/foo",
            "/opt-extra/foo",
            "/Volumes/External/cache",
        ] {
            assert!(!blocked(path), "{path} must be allowed");
        }
    }

    #[test]
    fn system_armor_blocks_home_folders_and_their_parents() {
        assert!(blocked("/Users/test"));
        assert!(blocked("/Users/test/"));
        assert!(blocked("/Users"));
        assert!(blocked("/Users/someone-else"));
        assert!(!blocked("/Users/test/Documents"));

        // A home outside /Users is protected through the account lookup alone.
        let custom = SystemArmor::with_homes(["/Volumes/Data/alice"]);
        assert!(custom.check(Path::new("/Volumes/Data/alice")).is_err());
        assert!(custom.check(Path::new("/Volumes/Data")).is_err());
        assert!(custom.check(Path::new("/Volumes/Data/alice/cache")).is_ok());

        if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
            if home.is_absolute() {
                assert!(SystemArmor::for_current_user().check(&home).is_err());
            }
        }
    }

    #[test]
    fn system_armor_rejects_parent_directory_traversal() {
        assert!(blocked(
            "/Users/test/Library/Caches/../../../../System/Library"
        ));
        assert!(blocked("/Users/test/Library/Caches/../foo"));
    }

    #[test]
    fn system_armor_resolves_symlinks_before_checking() {
        let root = temp_root("armor-symlink");
        fs::create_dir_all(&root).unwrap();
        let safe_target = root.join("cache");
        fs::create_dir_all(&safe_target).unwrap();

        let to_system = root.join("to-system");
        let to_system_upper = root.join("to-system-lower-case");
        let to_safe = root.join("to-cache");
        symlink("/System/Library", &to_system).unwrap();
        symlink("/system/library", &to_system_upper).unwrap();
        symlink(&safe_target, &to_safe).unwrap();

        let armor = armor();
        let error = armor.check(&to_system).unwrap_err();
        assert!(error.contains("resolves to"), "unexpected reason: {error}");
        assert!(armor.check(&to_system_upper).is_err());
        assert!(armor.check(&to_system.join("Caches")).is_err());
        assert!(armor.check(&safe_target).is_ok());
        assert!(armor.check(&to_safe).is_ok());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn purge_items_blocks_protected_paths_without_touching_them() {
        // Only paths that do not exist (or live under SIP-protected /System) are
        // used here, so a regression in the armor cannot delete anything real.
        let root = temp_root("purge-armor");
        fs::create_dir_all(&root).unwrap();
        let link = root.join("to-system");
        symlink("/System/Library", &link).unwrap();

        let report = purge_items(
            vec![
                "/SYSTEM/Library/Caches".to_owned(),
                "/applications/RustDisk-armor-test.app".to_owned(),
                "/Library/RustDisk-armor-test".to_owned(),
                "/opt/rustdisk-armor-test".to_owned(),
                link.to_string_lossy().into_owned(),
            ],
            DeletionMode::PermanentDelete,
        );

        assert_eq!(report.deleted_items_count, 0);
        assert_eq!(report.permanently_freed_physical_bytes, 0);
        assert_eq!(report.trashed_physical_bytes, 0);
        assert_eq!(report.errors.len(), 5, "{:?}", report.errors);
        assert!(report
            .errors
            .iter()
            .all(|error| error.starts_with("Blocked by System Armor:")));
        assert!(fs::symlink_metadata(&link).is_ok(), "the link must survive");

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn purge_items_reports_batch_success_and_physical_reclamation() {
        let root = temp_root("purge-success");
        fs::create_dir_all(root.join("nested")).unwrap();
        File::create(root.join("cache.bin"))
            .unwrap()
            .write_all(&vec![0u8; 32 * 1024])
            .unwrap();
        File::create(root.join("nested/artifact.bin"))
            .unwrap()
            .write_all(&vec![0u8; 16 * 1024])
            .unwrap();

        let report = purge_items(
            vec![root.to_string_lossy().into_owned()],
            DeletionMode::PermanentDelete,
        );
        assert!(report.permanently_freed_physical_bytes > 0);
        assert_eq!(
            report.trashed_physical_bytes, 0,
            "a permanent delete must not count anything as trashed"
        );
        assert_eq!(report.skipped_locked_count, 0);
        assert!(report.errors.is_empty());
        assert!(report.deleted_items_count >= 1);
        assert!(!root.exists());
    }

    /// Stands in for the system Trash: a rename on the same volume, which is
    /// exactly why trashed data keeps occupying space.
    fn fake_trash(trash_dir: &Path) -> impl Fn(&Path) -> Result<(), String> + '_ {
        move |path| {
            fs::create_dir_all(trash_dir).map_err(|error| error.to_string())?;
            let name = path.file_name().expect("item has a name");
            fs::rename(path, trash_dir.join(name)).map_err(|error| error.to_string())
        }
    }

    #[test]
    fn moving_to_trash_reports_trashed_bytes_and_no_freed_bytes() {
        let root = temp_root("purge-trash");
        let item = root.join("cache");
        let trash_dir = root.join("fake-trash");
        fs::create_dir_all(item.join("nested")).unwrap();
        File::create(item.join("cache.bin"))
            .unwrap()
            .write_all(&vec![0u8; 32 * 1024])
            .unwrap();
        File::create(item.join("nested/artifact.bin"))
            .unwrap()
            .write_all(&vec![0u8; 16 * 1024])
            .unwrap();

        let report = purge_with(
            vec![item.to_string_lossy().into_owned()],
            DeletionMode::MoveToTrash,
            &armor(),
            &fake_trash(&trash_dir),
        );

        assert!(
            report.trashed_physical_bytes >= 48 * 1024,
            "trashed {} bytes",
            report.trashed_physical_bytes
        );
        assert_eq!(
            report.permanently_freed_physical_bytes, 0,
            "trashed files still occupy the volume, so nothing is freed"
        );
        assert_eq!(report.deleted_items_count, 1);
        assert!(report.errors.is_empty(), "{:?}", report.errors);
        assert!(!item.exists());
        assert!(trash_dir.join("cache/cache.bin").exists());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_failed_trash_move_reports_no_bytes_at_all() {
        let root = temp_root("purge-trash-fails");
        fs::create_dir_all(&root).unwrap();
        let item = root.join("stuck.bin");
        File::create(&item)
            .unwrap()
            .write_all(&vec![0u8; 16 * 1024])
            .unwrap();

        let failing = |_: &Path| Err("the Trash is unavailable".to_owned());
        let report = purge_with(
            vec![item.to_string_lossy().into_owned()],
            DeletionMode::MoveToTrash,
            &armor(),
            &failing,
        );

        assert_eq!(report.trashed_physical_bytes, 0);
        assert_eq!(report.permanently_freed_physical_bytes, 0);
        assert_eq!(report.deleted_items_count, 0);
        assert_eq!(report.errors.len(), 1, "{:?}", report.errors);
        assert!(item.exists());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn purge_items_continues_after_an_invalid_path() {
        let root = temp_root("purge-partial");
        fs::create_dir_all(&root).unwrap();
        File::create(root.join("cache.bin"))
            .unwrap()
            .write_all(&vec![0u8; 8 * 1024])
            .unwrap();
        let missing = root.join("missing");

        let report = purge_items(
            vec![
                missing.to_string_lossy().into_owned(),
                root.to_string_lossy().into_owned(),
            ],
            DeletionMode::PermanentDelete,
        );
        assert_eq!(report.errors.len(), 1);
        assert!(report.deleted_items_count >= 1);
        assert!(!root.exists());
    }

    fn temp_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("rustdisk-{name}-{}", std::process::id()))
    }
}
