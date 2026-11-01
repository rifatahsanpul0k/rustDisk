use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Duration;

static THERMAL_LEVEL: AtomicU8 = AtomicU8::new(0);

#[uniffi::export]
pub fn set_thermal_level(level: u8) {
    THERMAL_LEVEL.store(level.min(3), Ordering::Relaxed);
}

#[uniffi::export]
pub fn get_thermal_level() -> u8 {
    THERMAL_LEVEL.load(Ordering::Relaxed)
}

#[cfg(target_os = "macos")]
extern "C" {
    fn setiopolicy_np(iotype: libc::c_int, scope: libc::c_int, policy: libc::c_int) -> libc::c_int;
}

#[cfg(target_os = "macos")]
const IOPOL_TYPE_DISK: libc::c_int = 0;
#[cfg(target_os = "macos")]
const IOPOL_SCOPE_THREAD: libc::c_int = 1;
#[cfg(target_os = "macos")]
const IOPOL_DEFAULT: libc::c_int = 0;
#[cfg(target_os = "macos")]
const IOPOL_THROTTLE: libc::c_int = 3;
#[cfg(target_os = "macos")]
const IOPOL_UTILITY: libc::c_int = 4;

thread_local! {
    static CURRENT_THREAD_THERMAL_LEVEL: std::cell::Cell<Option<u8>> = const { std::cell::Cell::new(None) };
}

pub fn apply_current_thread_thermal_policy() {
    let level = get_thermal_level();
    CURRENT_THREAD_THERMAL_LEVEL.with(|cell| cell.set(Some(level)));

    #[cfg(target_os = "macos")]
    unsafe {
        let (qos_class, io_policy) = match level {
            0 => (libc::qos_class_t::QOS_CLASS_USER_INITIATED, IOPOL_DEFAULT),
            1 => (libc::qos_class_t::QOS_CLASS_UTILITY, IOPOL_UTILITY),
            2..=u8::MAX => (libc::qos_class_t::QOS_CLASS_BACKGROUND, IOPOL_THROTTLE),
        };

        let _ = libc::pthread_set_qos_class_self_np(qos_class, 0);
        let _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, io_policy);
    }
}

pub fn thermal_pace_walk(counter: &mut u32) {
    *counter = counter.wrapping_add(1);
    let level = get_thermal_level();
    let reapply = CURRENT_THREAD_THERMAL_LEVEL.with(|cell| cell.get() != Some(level));
    if reapply {
        apply_current_thread_thermal_policy();
    }

    match level {
        1 => {
            if *counter % 500 == 0 {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        2 => {
            if *counter % 200 == 0 {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        3 => {
            if *counter % 100 == 0 {
                std::thread::sleep(Duration::from_millis(15));
            }
        }
        _ => {}
    }
}

pub fn thermal_pace_hash(chunk_index: u32) {
    let level = get_thermal_level();
    let reapply = CURRENT_THREAD_THERMAL_LEVEL.with(|cell| cell.get() != Some(level));
    if reapply {
        apply_current_thread_thermal_policy();
    }

    match level {
        1 => {
            if chunk_index > 0 && chunk_index % 64 == 0 {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        2 => {
            if chunk_index > 0 && chunk_index % 16 == 0 {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        3 => {
            if chunk_index > 0 && chunk_index % 8 == 0 {
                std::thread::sleep(Duration::from_millis(15));
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thermal_level_state_transitions_and_policy_application() {
        for level in 0..=3 {
            set_thermal_level(level);
            assert_eq!(get_thermal_level(), level);
            apply_current_thread_thermal_policy();
        }

        set_thermal_level(10);
        assert_eq!(get_thermal_level(), 3);
        apply_current_thread_thermal_policy();

        set_thermal_level(0);
        assert_eq!(get_thermal_level(), 0);
        apply_current_thread_thermal_policy();
    }

    #[test]
    fn thermal_pace_walk_and_hash_execute_safely() {
        set_thermal_level(1);
        let mut counter = 499;
        thermal_pace_walk(&mut counter);
        assert_eq!(counter, 500);

        thermal_pace_hash(64);
        set_thermal_level(0);
    }
}
