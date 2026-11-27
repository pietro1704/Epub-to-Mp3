//! Per-book chapter name overrides and the filename cover for clients.
use super::*;
use converter_core::chapter_names::{filename_cover, ChapterNameOverrides};

pub(super) fn chapter_names_update_json(
    path: &Path,
    index: Option<&str>,
    name: Option<&str>,
) -> Result<String, String> {
    let mut names = ChapterNameOverrides::load(path).map_err(|error| error.to_string())?;
    if let Some(index) = index {
        // A missing or blank name resets the chapter to its automatic name.
        names.set(index, name.unwrap_or(""))?;
        names.save(path).map_err(|error| error.to_string())?;
    }
    serde_json::to_string(&names).map_err(|error| error.to_string())
}

fn json_result(result: Result<String, String>) -> *mut c_char {
    match result.and_then(|json| {
        CString::new(json).map_err(|error| format!("result contains NUL: {error}"))
    }) {
        Ok(value) => value.into_raw(),
        Err(error) => fail(error),
    }
}

/// Reads or updates the overrides file at a NUL-terminated UTF-8 path and returns
/// `{"names": {chapterIndex: name}}`. A null `index` only reads; a non-null `index` sets its
/// name, and a null or blank `name` resets it. On failure, returns null and stores the error
/// for `converter_last_error`. Free the result with `converter_string_free`.
#[no_mangle]
pub unsafe extern "C" fn converter_chapter_names_update_json_v1(
    path: *const c_char,
    index: *const c_char,
    name: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_chapter_names_update_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let path = match c_string(path, "path") {
                Ok(path) => path,
                Err(error) => return fail(error),
            };
            let optional = |value: *const c_char, label: &str| {
                if value.is_null() {
                    Ok(None)
                } else {
                    c_string(value, label).map(Some)
                }
            };
            let (index, name) = match (optional(index, "index"), optional(name, "name")) {
                (Ok(index), Ok(name)) => (index, name),
                (Err(error), _) | (_, Err(error)) => return fail(error),
            };
            json_result(chapter_names_update_json(
                Path::new(&path),
                index.as_deref(),
                name.as_deref(),
            ))
        },
    )
}

/// Returns `{"label", "backgroundRgb": [r, g, b]}` for a book file name, the cover clients
/// draw when the book has none. Free the result with `converter_string_free`.
#[no_mangle]
pub unsafe extern "C" fn converter_filename_cover_json_v1(file_name: *const c_char) -> *mut c_char {
    ffi_guard(
        "converter_filename_cover_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let file_name = match c_string(file_name, "file_name") {
                Ok(value) => value,
                Err(error) => return fail(error),
            };
            let cover = filename_cover(&file_name);
            json_result(Ok(json!({
                "label": cover.label,
                "backgroundRgb": cover.background_rgb,
            })
            .to_string()))
        },
    )
}
