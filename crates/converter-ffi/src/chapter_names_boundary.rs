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

pub(super) fn pdf_image_pages_json(path: &str) -> Result<String, String> {
    let source = std::fs::read(path).map_err(|error| error.to_string())?;
    converter_core::ingestion::pdf_text::PdfTextIngestion::image_pages(Path::new(path), &source)
        .map_err(|error| error.to_string())
        .map(|pages| json!({ "pages": pages }).to_string())
}

pub(super) fn pdf_ocr_page_set_json(path: &str, page: &str, text: &str) -> Result<String, String> {
    let page = page
        .trim()
        .parse::<u32>()
        .map_err(|error| error.to_string())?;
    let book = Path::new(path);
    let mut pages = converter_core::ocr_pages::OcrPages::load(book).map_err(|e| e.to_string())?;
    pages.set(page, text);
    pages.save(book).map_err(|error| error.to_string())?;
    serde_json::to_string(&pages).map_err(|error| error.to_string())
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

pub(super) fn filename_cover_json(file_name: &str) -> String {
    let cover = filename_cover(file_name);
    json!({
        "label": cover.label,
        "backgroundRgb": cover.background_rgb,
    })
    .to_string()
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
            json_result(Ok(filename_cover_json(&file_name)))
        },
    )
}

/// Returns `{"pages": [n, ...]}`: the 1-based pages of a PDF that draw content but have no
/// text layer, which a client OCR reads. Free the result with `converter_string_free`.
#[no_mangle]
pub unsafe extern "C" fn converter_pdf_image_pages_json_v1(path: *const c_char) -> *mut c_char {
    ffi_guard(
        "converter_pdf_image_pages_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let path = match c_string(path, "path") {
                Ok(value) => value,
                Err(error) => return fail(error),
            };
            let result = pdf_image_pages_json(&path);
            json_result(result)
        },
    )
}

/// Stores (or, with a null or blank `text`, clears) the text a client OCR recognised for one
/// 1-based page of a PDF, in the `<pdf>.ocr.json` sidecar read on every open, and returns
/// `{"pages": {page: text}}`. Free the result with `converter_string_free`.
#[no_mangle]
pub unsafe extern "C" fn converter_pdf_ocr_page_set_json_v1(
    path: *const c_char,
    page: *const c_char,
    text: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_pdf_ocr_page_set_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let path = match c_string(path, "path") {
                Ok(value) => value,
                Err(error) => return fail(error),
            };
            let page = match c_string(page, "page") {
                Ok(value) => value,
                Err(error) => return fail(error),
            };
            let text = if text.is_null() {
                String::new()
            } else {
                match c_string(text, "text") {
                    Ok(value) => value,
                    Err(error) => return fail(error),
                }
            };
            let result = pdf_ocr_page_set_json(&path, &page, &text);
            json_result(result)
        },
    )
}
