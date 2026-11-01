use thiserror::Error;

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum RiskTier {
    Safe,
    Rebuildable,
    HighRiskCli,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectActivity {
    Stale,
    Active,
    NotProject,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeletionMode {
    MoveToTrash,
    PermanentDelete,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum DuplicateKind {
    DuplicateFile,
    DuplicateFolder,
    DuplicatePackage,
}

#[derive(uniffi::Record, Debug, Clone, Copy)]
pub struct DiskOverview {
    pub total_bytes: u64,
    pub available_bytes: u64,
    pub used_bytes: u64,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct CleanupReport {
    /// Physical bytes moved to the Trash. They stay allocated on the volume until
    /// the Trash is emptied, so this is not reclaimed space. Always 0 for a
    /// permanent delete.
    pub trashed_physical_bytes: u64,
    /// Physical bytes permanently removed, which is the space actually reclaimed.
    /// Always 0 when moving to the Trash.
    pub permanently_freed_physical_bytes: u64,
    /// Items moved to the Trash or deleted, depending on the mode.
    pub deleted_items_count: u32,
    pub skipped_locked_count: u32,
    pub errors: Vec<String>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct ScannedItem {
    pub id: String,
    pub name: String,
    pub path: String,
    pub physical_bytes: u64,
    pub logical_bytes: u64,
    pub category: String,
    pub risk: RiskTier,
    pub activity: ProjectActivity,
    pub days_since_modified: u64,
    pub ecosystem: String,
    pub project_root: String,
    pub restore_hint: String,
    pub has_git: bool,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct TerminalPackage {
    pub id: String,
    pub name: String,
    pub manager: String,
    pub path: String,
    pub physical_bytes: u64,
    pub logical_bytes: u64,
    pub version_count: u32,
    pub installed_on_request: bool,
    pub risk: RiskTier,
    pub uninstall_cmd: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct PackageActionReport {
    pub success: bool,
    pub command_run: String,
    pub freed_physical_bytes: u64,
    pub stdout: String,
    pub stderr: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct DuplicateMember {
    pub id: String,
    pub name: String,
    pub path: String,
    pub physical_bytes: u64,
    pub logical_bytes: u64,
    pub days_since_modified: u64,
    pub is_keep_recommended: bool,
    pub source_label: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct DuplicateGroup {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub kind: DuplicateKind,
    pub category: String,
    pub single_item_bytes: u64,
    pub reclaimable_physical_bytes: u64,
    pub members: Vec<DuplicateMember>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FullAuditOptions {
    pub root_path: String,
    pub stale_threshold_days: u64,
    pub large_file_threshold_bytes: u64,
    pub include_dev_caches_in_large_files: bool,
    pub duplicate_min_size_bytes: u64,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FullAuditReport {
    pub safe_caches: Vec<ScannedItem>,
    pub project_artifacts: Vec<ScannedItem>,
    pub terminal_packages: Vec<TerminalPackage>,
    pub large_files: Vec<ScannedItem>,
    pub duplicate_groups: Vec<DuplicateGroup>,
    pub disk_overview: DiskOverview,
}

#[derive(uniffi::Error, Debug, Error)]
pub enum RustDiskError {
    #[error("{message}")]
    Message { message: String },
}

impl RustDiskError {
    pub(crate) fn message(message: impl Into<String>) -> Self {
        Self::Message {
            message: message.into(),
        }
    }
}
