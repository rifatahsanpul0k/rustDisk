//! Cooperative cancellation for long-running scans.
//!
//! Every exported scan entry point calls [`ScanToken::begin`] once and passes
//! the returned token down to its directory walkers, rayon closures and hashing
//! loops. Calling [`cancel_active_scan`] flips the flag of every scan that is
//! still running, and each of them stops at its next check.
//!
//! The flag is per scan rather than one global boolean. A single global flag
//! that is "reset at the start of every scan" races with back-to-back
//! cancel-and-restart: the new scan clears the flag before the old scan has
//! noticed it, so the old scan keeps burning CPU and disk. With one flag per
//! scan, starting a new scan can never un-cancel an older one.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Weak};

/// Cancellation flag observed by one running scan.
#[derive(Clone, Debug)]
pub(crate) struct ScanToken(Arc<AtomicBool>);

impl ScanToken {
    /// Starts a new scan: returns a fresh, un-cancelled token that
    /// [`cancel_active_scan`] can reach.
    pub(crate) fn begin() -> Self {
        ACTIVE_SCANS.begin()
    }

    /// A token that no caller can cancel globally. Used for non-scan work that
    /// shares scan helpers (for example measuring a folder before deleting it).
    pub(crate) fn never() -> Self {
        Self(Arc::new(AtomicBool::new(false)))
    }

    #[inline]
    pub(crate) fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }

    #[cfg(test)]
    pub(crate) fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

/// Weakly tracks the flag of every running scan. Weak references mean a
/// finished scan drops out on its own when its token is dropped.
struct ScanRegistry {
    live: Mutex<Vec<Weak<AtomicBool>>>,
}

impl ScanRegistry {
    const fn new() -> Self {
        Self {
            live: Mutex::new(Vec::new()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Vec<Weak<AtomicBool>>> {
        // A poisoned lock only means another scan panicked; the list is still valid.
        self.live
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn begin(&self) -> ScanToken {
        let flag = Arc::new(AtomicBool::new(false));
        let mut live = self.lock();
        live.retain(|scan| scan.strong_count() > 0);
        live.push(Arc::downgrade(&flag));
        ScanToken(flag)
    }

    fn cancel_all(&self) {
        for flag in self.lock().iter().filter_map(Weak::upgrade) {
            flag.store(true, Ordering::Relaxed);
        }
    }
}

static ACTIVE_SCANS: ScanRegistry = ScanRegistry::new();

/// Asks every scan that is currently running to stop as soon as possible.
///
/// Cancelled scans return an empty result. Scans started after this call are
/// not affected.
#[uniffi::export]
pub fn cancel_active_scan() {
    ACTIVE_SCANS.cancel_all();
}

#[cfg(test)]
mod tests {
    use super::ScanRegistry;

    #[test]
    fn new_tokens_start_uncancelled_and_cancel_all_reaches_every_running_scan() {
        let registry = ScanRegistry::new();
        let first = registry.begin();
        let second = registry.begin();
        assert!(!first.is_cancelled());
        assert!(!second.is_cancelled());

        registry.cancel_all();
        assert!(first.is_cancelled());
        assert!(second.is_cancelled());
    }

    #[test]
    fn starting_a_new_scan_does_not_uncancel_an_older_one() {
        let registry = ScanRegistry::new();
        let old = registry.begin();
        registry.cancel_all();

        let new = registry.begin();
        assert!(
            old.is_cancelled(),
            "a restart must not clear an earlier cancel"
        );
        assert!(!new.is_cancelled(), "a scan started after cancel must run");
    }

    #[test]
    fn finished_scans_are_forgotten() {
        let registry = ScanRegistry::new();
        drop(registry.begin());
        drop(registry.begin());
        let _running = registry.begin();
        assert_eq!(registry.lock().len(), 1);
    }

    #[test]
    fn never_tokens_ignore_the_registry() {
        let registry = ScanRegistry::new();
        let detached = super::ScanToken::never();
        registry.cancel_all();
        assert!(!detached.is_cancelled());
    }
}
