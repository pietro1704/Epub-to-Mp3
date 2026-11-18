use super::*;

/// Returns the most recent error for the current thread, transferring ownership to the caller.
#[no_mangle]
pub unsafe extern "C" fn converter_last_error() -> *mut c_char {
    ffi_guard("converter_last_error", std::ptr::null_mut(), || {
        LAST_ERROR.with(|error| match error.borrow_mut().take() {
            Some(error) => CString::new(error).map_or(ptr::null_mut(), CString::into_raw),
            None => ptr::null_mut(),
        })
    })
}

/// Frees an opaque session handle. Null is accepted.
#[no_mangle]
pub unsafe extern "C" fn converter_session_free(handle: *mut ConverterSession) {
    ffi_guard("converter_session_free", (), || {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    })
}

/// Frees a string returned by this crate. Null is accepted.
#[no_mangle]
pub unsafe extern "C" fn converter_string_free(value: *mut c_char) {
    ffi_guard("converter_string_free", (), || {
        if !value.is_null() {
            drop(CString::from_raw(value));
        }
    })
}
