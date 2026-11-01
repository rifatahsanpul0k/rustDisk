use crate::DiskOverview;
use std::ffi::CString;

/// Reads APFS volume capacity and available blocks from the Data volume.
#[uniffi::export]
pub fn get_disk_overview() -> DiskOverview {
    let paths = ["/System/Volumes/Data", "/"];

    for path in paths {
        let Ok(path) = CString::new(path) else {
            continue;
        };

        let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        let result = unsafe { libc::statvfs(path.as_ptr(), stats.as_mut_ptr()) };
        if result == 0 {
            let stats = unsafe { stats.assume_init() };
            let block_size = if stats.f_frsize > 0 {
                stats.f_frsize as u64
            } else {
                stats.f_bsize as u64
            };
            let total_bytes = (stats.f_blocks as u64).saturating_mul(block_size);
            let available_bytes = (stats.f_bavail as u64).saturating_mul(block_size);
            let used_bytes = total_bytes.saturating_sub(available_bytes);
            return DiskOverview {
                total_bytes,
                available_bytes,
                used_bytes,
            };
        }
    }

    DiskOverview {
        total_bytes: 0,
        available_bytes: 0,
        used_bytes: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::get_disk_overview;

    #[test]
    fn disk_overview_returns_a_consistent_non_negative_snapshot() {
        let overview = get_disk_overview();
        assert!(overview.total_bytes >= overview.available_bytes);
        assert_eq!(
            overview.used_bytes,
            overview
                .total_bytes
                .saturating_sub(overview.available_bytes)
        );
    }
}
