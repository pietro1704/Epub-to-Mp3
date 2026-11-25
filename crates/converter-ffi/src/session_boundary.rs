use super::*;

/// Opens and parses an EPUB or text-layer PDF at a NUL-terminated UTF-8 path.
///
/// On failure, returns null and stores a thread-local error retrievable with
/// `converter_last_error`.
#[no_mangle]
pub unsafe extern "C" fn converter_session_open(path: *const c_char) -> *mut ConverterSession {
    ffi_guard("converter_session_open", std::ptr::null_mut(), || {
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
            Ok(session) => Box::into_raw(Box::new(ConverterSession {
                session,
                platform_tts: None,
            })),
            // The additive code lets clients explain an image-only PDF page.
            Err(error) => fail(error.message_with_code()),
        }
    })
}

/// Returns metadata as an owned UTF-8 JSON string, or null for an invalid handle.
#[no_mangle]
pub unsafe extern "C" fn converter_session_metadata_json(
    handle: *const ConverterSession,
) -> *mut c_char {
    ffi_guard(
        "converter_session_metadata_json",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let session = match handle.as_ref() {
                Some(handle) => handle,
                None => return fail("invalid null session handle".to_owned()),
            };
            let metadata = metadata_json(
                session.session.metadata(),
                session.session.structure_verification(),
            );
            match CString::new(metadata) {
                Ok(value) => value.into_raw(),
                Err(error) => fail(format!("metadata contains an interior NUL byte: {error}")),
            }
        },
    )
}
