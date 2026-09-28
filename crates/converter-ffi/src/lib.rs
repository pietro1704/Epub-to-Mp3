//! Stable C ABI for opening embedded EPUB conversion sessions.
//!
//! Ownership contract:
//! - `converter_session_open` returns an owned opaque handle, or null on error.
//! - `converter_session_metadata_json` returns an owned UTF-8 string, or null on error.
//! - `converter_session_free` and `converter_string_free` accept null and are no-ops.
//! - `converter_last_error` returns an owned UTF-8 error string, or null when no error exists.
//! - Every returned string must be released with `converter_string_free`.

use converter_core::{
    config::AppConfig,
    embedded::{EmbeddedBookMetadata, EmbeddedConversionSession},
    paths::resolve_paths_from,
};
use serde_json::json;
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    path::Path,
    ptr,
};

/// Opaque session handle owned by the caller.
#[repr(C)]
pub struct ConverterSession {
    session: EmbeddedConversionSession,
}

/// Opens and parses an EPUB at a NUL-terminated UTF-8 path.
///
/// On failure, returns null and stores a thread-local error retrievable with
/// `converter_last_error`.
#[no_mangle]
pub unsafe extern "C" fn converter_session_open(path: *const c_char) -> *mut ConverterSession {
    clear_last_error();
    let path = match c_string(path, "path") {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    let config = AppConfig::from_paths(resolve_paths_from(
        HashMap::<String, String>::new(),
        std::env::temp_dir().join("converter-ffi"),
    ));
    match EmbeddedConversionSession::open(Path::new(&path), Default::default(), config) {
        Ok(session) => Box::into_raw(Box::new(ConverterSession { session })),
        Err(error) => fail(error.to_string()),
    }
}

/// Returns metadata as an owned UTF-8 JSON string, or null for an invalid handle.
#[no_mangle]
pub unsafe extern "C" fn converter_session_metadata_json(
    handle: *const ConverterSession,
) -> *mut c_char {
    clear_last_error();
    let session = match handle.as_ref() {
        Some(handle) => handle,
        None => return fail("invalid null session handle".to_owned()),
    };
    let metadata = metadata_json(session.session.metadata());
    match CString::new(metadata) {
        Ok(value) => value.into_raw(),
        Err(error) => fail(format!("metadata contains an interior NUL byte: {error}")),
    }
}

/// Returns the most recent error for the current thread, transferring ownership to the caller.
#[no_mangle]
pub unsafe extern "C" fn converter_last_error() -> *mut c_char {
    LAST_ERROR.with(|error| match error.borrow_mut().take() {
        Some(error) => CString::new(error).map_or(ptr::null_mut(), CString::into_raw),
        None => ptr::null_mut(),
    })
}

/// Frees an opaque session handle. Null is accepted.
#[no_mangle]
pub unsafe extern "C" fn converter_session_free(handle: *mut ConverterSession) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Frees a string returned by this crate. Null is accepted.
#[no_mangle]
pub unsafe extern "C" fn converter_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

fn clear_last_error() {
    LAST_ERROR.with(|error| error.borrow_mut().take());
}

fn fail<T>(error: String) -> T {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(error));
    // This function is only called at null-returning ABI boundaries.
    unsafe { std::mem::zeroed() }
}

unsafe fn c_string(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("invalid null {name}"));
    }
    CStr::from_ptr(value)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| format!("{name} must be valid UTF-8"))
}

fn metadata_json(metadata: &EmbeddedBookMetadata) -> String {
    json!({
        "title": metadata.title,
        "author": metadata.author,
        "language": metadata.language,
        "chapters": metadata.chapters.iter().map(|chapter| json!({
            "index": chapter.index,
            "name": chapter.name,
            "sourcePath": chapter.source_path,
            "textChars": chapter.text_chars,
            "level": chapter.level,
        })).collect::<Vec<_>>(),
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{ffi::CString, io::Write, ptr};
    use zip::{write::FileOptions, ZipWriter};

    fn fixture() -> tempfile::NamedTempFile {
        let file = tempfile::NamedTempFile::new().expect("temporary EPUB");
        let mut zip = ZipWriter::new(file.reopen().expect("reopen fixture"));
        let options = FileOptions::<()>::default();
        zip.start_file("META-INF/container.xml", options).unwrap();
        zip.write_all(br#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#).unwrap();
        zip.start_file("OEBPS/content.opf", options).unwrap();
        zip.write_all(br#"<package xmlns:dc="x"><metadata><title>Test Book</title><creator>Author</creator><language>en</language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#).unwrap();
        zip.start_file("OEBPS/chapter.xhtml", options).unwrap();
        zip.write_all(b"<html><body><p>Hello world.</p></body></html>")
            .unwrap();
        zip.finish().unwrap();
        file
    }

    #[test]
    fn null_handles_report_errors_and_free_safely() {
        unsafe {
            converter_session_free(ptr::null_mut());
            converter_string_free(ptr::null_mut());
            assert!(converter_session_metadata_json(ptr::null()).is_null());
            let error = converter_last_error();
            assert_eq!(
                CStr::from_ptr(error).to_str().unwrap(),
                "invalid null session handle"
            );
            converter_string_free(error);
        }
    }

    #[test]
    fn invalid_path_reports_error() {
        let path = CString::new("/definitely/missing/book.epub").unwrap();
        unsafe {
            assert!(converter_session_open(path.as_ptr()).is_null());
            let error = converter_last_error();
            assert!(CStr::from_ptr(error)
                .to_str()
                .unwrap()
                .contains("failed to read input"));
            converter_string_free(error);
        }
    }

    #[test]
    fn valid_session_returns_metadata_json() {
        let fixture = fixture();
        let path = CString::new(fixture.path().to_str().unwrap()).unwrap();
        unsafe {
            let handle = converter_session_open(path.as_ptr());
            assert!(!handle.is_null());
            let metadata = converter_session_metadata_json(handle);
            let json = CStr::from_ptr(metadata).to_str().unwrap();
            assert!(json.contains("Test Book"));
            assert!(json.contains("chapters"));
            converter_string_free(metadata);
            converter_session_free(handle);
        }
    }
}
