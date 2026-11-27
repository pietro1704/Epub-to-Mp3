//! MP3 export of a finished book: one file or one file per chapter ("NN - title").
use super::*;
use converter_core::audio::{export_mp3, ExportBook, ExportChapter, ExportFormat, ExportLayout};

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExportRequest {
    destination: String,
    /// "single" or "perChapter".
    layout: String,
    title: String,
    author: Option<String>,
    cover: Option<String>,
    chapters: Vec<ExportChapterRequest>,
}

#[derive(serde::Deserialize)]
struct ExportChapterRequest {
    title: String,
    path: String,
}

/// Runs the request and returns `{"files": [path, ...]}` in chapter order.
pub(super) fn export_json(request: &str) -> Result<String, String> {
    let request: ExportRequest = serde_json::from_str(request)
        .map_err(|error| format!("invalid export request: {error}"))?;
    let layout = match request.layout.as_str() {
        "single" => ExportLayout::SingleFile,
        "perChapter" => ExportLayout::PerChapter,
        other => return Err(format!("unknown export layout: {other}")),
    };
    let cover = request.cover.as_deref().map(Path::new);
    let book = ExportBook {
        title: &request.title,
        author: request.author.as_deref(),
        cover,
    };
    let chapters: Vec<ExportChapter> = request
        .chapters
        .into_iter()
        .map(|chapter| ExportChapter {
            title: chapter.title,
            path: chapter.path.into(),
        })
        .collect();
    let files = export_mp3(
        Path::new(&request.destination),
        &book,
        &chapters,
        layout,
        ExportFormat::Mp3,
    )
    .map_err(|error| error.to_string())?;
    Ok(json!({ "files": files }).to_string())
}

/// Exports MP3 files from a JSON request (`destination`, `layout`, `title`, `author?`,
/// `cover?`, `chapters: [{title, path}]`) and returns `{"files": [...]}`. Free the result with
/// `converter_string_free`; on failure returns null and stores the error.
#[no_mangle]
pub unsafe extern "C" fn converter_export_mp3_json_v1(request: *const c_char) -> *mut c_char {
    ffi_guard("converter_export_mp3_json_v1", std::ptr::null_mut(), || {
        clear_last_error();
        let request = match c_string(request, "request") {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match export_json(&request).and_then(|json| {
            CString::new(json).map_err(|error| format!("result contains NUL: {error}"))
        }) {
            Ok(value) => value.into_raw(),
            Err(error) => fail(error),
        }
    })
}
