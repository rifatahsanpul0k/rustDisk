mod cancel;
mod cleaner;
mod duplicates;
mod models;
mod packages;
mod projects;
mod scanner;
mod telemetry;

use std::sync::Once;

static SCAN_THREAD_POOL: Once = Once::new();

pub(crate) fn configure_scan_thread_pool() {
    SCAN_THREAD_POOL.call_once(|| {
        let cores = std::thread::available_parallelism()
            .map(|count| count.get())
            .unwrap_or(2);
        let threads = cores.min(2).max(1);
        let _ = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .thread_name(|index| format!("rustdisk-scan-{index}"))
            .build_global();
    });
}

pub use cancel::cancel_active_scan;
pub use cleaner::{delete_item, purge_items};
pub use duplicates::scan_duplicates;
pub use models::{
    CleanupReport, DeletionMode, DiskOverview, DuplicateGroup, DuplicateKind, DuplicateMember,
    PackageActionReport, ProjectActivity, RiskTier, RustDiskError, ScannedItem, TerminalPackage,
};
pub use packages::{run_package_maintenance, run_terminal_uninstall, scan_terminal_packages};
pub use projects::scan_project_artifacts;
pub use scanner::{scan_large_files, scan_large_files_with_options, scan_safe_caches};
pub use telemetry::get_disk_overview;

uniffi::setup_scaffolding!();
