//! Library-shelf metadata for clients that list books before opening them.
use super::*;
use base64::Engine as _;

/// Covers above this size are left to the reader instead of the shelf card.
const MAX_SHELF_COVER_BYTES: usize = 2 * 1024 * 1024;

pub(super) fn library_metadata_json(path: &Path) -> Result<String, String> {
    let file = std::fs::File::open(path).map_err(|error| format!("cannot open book: {error}"))?;
    let metadata = converter_core::epub::read_library_metadata(std::io::BufReader::new(file))
        .map_err(|error| error.to_string())?;
    let cover = metadata
        .cover
        .filter(|bytes| bytes.len() <= MAX_SHELF_COVER_BYTES);
    Ok(json!({
        "title": metadata.title,
        "author": metadata.author,
        "language": metadata.language,
        "coverMimeType": cover.as_ref().and(metadata.cover_mime),
        "coverBase64": cover.map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes)),
    })
    .to_string())
}

/// Returns `{title, author, language, coverMimeType, coverBase64}` for the EPUB
/// at a NUL-terminated UTF-8 path, reading only its package document and cover.
/// Absent values are JSON null. On failure, returns null and stores the error
/// for `converter_last_error`. Free the result with `converter_string_free`.
#[no_mangle]
pub unsafe extern "C" fn converter_book_library_metadata_json_v1(
    path: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_book_library_metadata_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let path = match c_string(path, "path") {
                Ok(path) => path,
                Err(error) => return fail(error),
            };
            match library_metadata_json(Path::new(&path)).and_then(|json| {
                CString::new(json).map_err(|error| format!("metadata contains NUL: {error}"))
            }) {
                Ok(value) => value.into_raw(),
                Err(error) => fail(error),
            }
        },
    )
}
