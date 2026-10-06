//! Small, ownership-safe C ABI over converter-core for Swift callers.

use std::ffi::{CStr, CString, c_char};
use std::ptr;

use converter_core::{AudioFormat, Engine};

/// Returns the ABI version. The returned pointer is static and must not be freed.
#[unsafe(no_mangle)]
pub extern "C" fn converter_ffi_abi_version() -> u32 {
    1
}

/// Validates an engine name. Returns 1 for supported values, 0 otherwise.
#[unsafe(no_mangle)]
pub extern "C" fn converter_ffi_engine_supported(value: *const c_char) -> i32 {
    parse_cstr(value).is_some_and(|value| value.parse::<Engine>().is_ok()) as i32
}

/// Returns a newly allocated UTF-8 extension for a supported format.
/// The caller releases it with `converter_ffi_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn converter_ffi_audio_extension(value: *const c_char) -> *mut c_char {
    let Some(value) = parse_cstr(value) else {
        return ptr::null_mut();
    };
    let Ok(format) = value.parse::<AudioFormat>() else {
        return ptr::null_mut();
    };
    CString::new(format.extension()).map_or(ptr::null_mut(), CString::into_raw)
}

/// Releases a string returned by this library. Null is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn converter_ffi_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

fn parse_cstr(value: *const c_char) -> Option<&'static str> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value).to_str().ok() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn exposes_stable_abi_and_validation() {
        assert_eq!(converter_ffi_abi_version(), 1);
        let edge = CString::new("edge").unwrap();
        let invalid = CString::new("wat").unwrap();
        assert_eq!(converter_ffi_engine_supported(edge.as_ptr()), 1);
        assert_eq!(converter_ffi_engine_supported(invalid.as_ptr()), 0);
    }
}
