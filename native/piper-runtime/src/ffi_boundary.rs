use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};

pub(super) fn guard<T>(fallback: T, action: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(result) => result,
        Err(payload) => {
            if let Err(nested) = catch_unwind(AssertUnwindSafe(|| drop(payload))) {
                std::mem::forget(nested);
            }
            fallback
        }
    }
}

pub(super) unsafe fn input<'a>(value: *const c_char, name: &str) -> Result<&'a str, String> {
    if value.is_null() {
        return Err(format!("Invalid null Piper {name}"));
    }
    CStr::from_ptr(value)
        .to_str()
        .map_err(|_| format!("Piper {name} must be valid UTF-8"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_and_invalid_utf8_are_rejected_before_model_loading() {
        let mut error = [0 as c_char; 256];
        assert_eq!(
            crate::piper_runtime_init(
                std::ptr::null(),
                std::ptr::null(),
                error.as_mut_ptr(),
                error.len() as u32
            ),
            0
        );
        assert_eq!(
            unsafe { CStr::from_ptr(error.as_ptr()) }.to_str().unwrap(),
            "Invalid null Piper model"
        );
        let invalid = [0xff_u8, 0];
        assert_eq!(
            crate::piper_runtime_init(
                invalid.as_ptr().cast(),
                std::ptr::null(),
                error.as_mut_ptr(),
                error.len() as u32
            ),
            0
        );
        assert_eq!(
            unsafe { CStr::from_ptr(error.as_ptr()) }.to_str().unwrap(),
            "Piper model must be valid UTF-8"
        );
        assert!(unsafe { input(std::ptr::null(), "text") }.is_err());
        assert!(unsafe { input(std::ptr::null(), "output") }.is_err());
        // A later ABI call still works; no model or runtime was initialized.
        assert_eq!(crate::piper_runtime_status().engine_ready, 0);
    }
}
