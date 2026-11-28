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

const DEFAULT_SHELF_COVER_EDGE: u32 = 480;
const MAX_SHELF_COVER_EDGE: u32 = 2048;

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ShelfRequest {
    paths: Vec<std::path::PathBuf>,
    cover_max_edge: Option<u32>,
}

fn library_shelf_json(request: &str) -> Result<String, String> {
    let request: ShelfRequest = serde_json::from_str(request)
        .map_err(|error| format!("invalid library shelf request: {error}"))?;
    let edge = request.cover_max_edge.unwrap_or(DEFAULT_SHELF_COVER_EDGE);
    if !(1..=MAX_SHELF_COVER_EDGE).contains(&edge) {
        return Err(format!(
            "coverMaxEdge must be between 1 and {MAX_SHELF_COVER_EDGE}"
        ));
    }
    let books: Vec<_> = converter_core::epub::read_library_shelf(&request.paths, edge)
        .into_iter()
        .map(|book| match book {
            Ok(metadata) => json!({
                "title": metadata.title,
                "author": metadata.author,
                "language": metadata.language,
                "coverMimeType": metadata.cover_mime,
                "coverBase64": metadata.cover.map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes)),
                "error": null,
            }),
            Err(error) => json!({
                "title": null,
                "author": null,
                "language": null,
                "coverMimeType": null,
                "coverBase64": null,
                "error": error.to_string(),
            }),
        })
        .collect();
    Ok(json!({ "books": books }).to_string())
}

/// Batch form of the shelf call. The request is
/// `{"paths": [...], "coverMaxEdge": 480}` (`coverMaxEdge` is optional, 1 to
/// 2048). Returns `{"books": [...]}` in request order, each entry shaped like
/// the single-book result plus `error`, with the cover as a JPEG thumbnail. An
/// unreadable book only sets its own `error`. Returns null for an invalid
/// request and stores the error for `converter_last_error`. Free the result
/// with `converter_string_free`.
#[no_mangle]
pub unsafe extern "C" fn converter_book_library_shelf_json_v1(
    request_json: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_book_library_shelf_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let request = match c_string(request_json, "request_json") {
                Ok(request) => request,
                Err(error) => return fail(error),
            };
            match library_shelf_json(&request).and_then(|json| {
                CString::new(json).map_err(|error| format!("metadata contains NUL: {error}"))
            }) {
                Ok(value) => value.into_raw(),
                Err(error) => fail(error),
            }
        },
    )
}
