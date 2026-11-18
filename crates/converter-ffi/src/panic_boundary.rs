//! Contain Rust unwinding before returning through a foreign ABI. Pointer
//! validity and foreign exceptions remain the caller's responsibility.

use std::panic::{catch_unwind, AssertUnwindSafe};

fn catch_boundary<T>(operation: &str, action: impl FnOnce() -> T) -> Result<T, ()> {
    catch_unwind(AssertUnwindSafe(action)).map_err(|payload| {
        // A panic payload may itself have a panicking destructor. Dispose of
        // ordinary payloads; never let a second unwind escape the boundary.
        if let Err(nested) = catch_unwind(AssertUnwindSafe(|| drop(payload))) {
            std::mem::forget(nested);
        }
        let _ = super::LAST_ERROR.try_with(|slot| {
            if let Ok(mut error) = slot.try_borrow_mut() {
                *error = Some(format!("{operation} panicked"));
            }
        });
    })
}

pub(super) fn ffi_guard<T>(operation: &str, fallback: T, action: impl FnOnce() -> T) -> T {
    catch_boundary(operation, action).unwrap_or(fallback)
}

#[cfg(any(
    all(target_os = "android", feature = "android-jni"),
    all(test, feature = "android-jni")
))]
pub(super) fn jni_guard<T>(
    environment: *mut jni::sys::JNIEnv,
    operation: &str,
    fallback: T,
    action: impl FnOnce() -> T,
) -> T {
    match catch_boundary(operation, action) {
        Ok(value) => value,
        Err(()) => {
            // The original JNIEnv borrow has ended with the closure. Reborrow
            // on this same thread only to report failure to Java, including
            // methods whose normal successful result is null or void.
            let _ = catch_boundary("JNI panic reporting", || unsafe {
                if let Ok(mut env) = jni::JNIEnv::from_raw(environment) {
                    if !env.exception_check().unwrap_or(true) {
                        let _ = env.throw_new(
                            "java/lang/RuntimeException",
                            format!("{operation} panicked"),
                        );
                    }
                }
            });
            fallback
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secondary_payload_panic_is_contained_and_error_stays_thread_local() {
        struct PanickingPayload;
        impl Drop for PanickingPayload {
            fn drop(&mut self) {
                panic!("payload destructor");
            }
        }
        super::super::fail::<()>("parent error".into());
        std::thread::spawn(|| {
            assert!(!ffi_guard("payload fixture", false, || {
                std::panic::panic_any(PanickingPayload)
            }));
            assert_eq!(
                super::super::LAST_ERROR.with(|slot| slot.borrow_mut().take()),
                Some("payload fixture panicked".into())
            );
            assert_eq!(ffi_guard("success", 0, || 42), 42);
        })
        .join()
        .unwrap();
        assert_eq!(
            super::super::LAST_ERROR.with(|slot| slot.borrow_mut().take()),
            Some("parent error".into())
        );
    }
}
