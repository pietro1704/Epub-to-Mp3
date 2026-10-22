//! Bounded upload ingestion and permitted local-source intake.
use super::http_input_paths::uuid;
use super::http_runtime_state::{AppState, LocalUpload, UploadResponse};
use axum::extract::ConnectInfo;
use axum::extract::Multipart;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use std::net::SocketAddr;
use std::path::Path;
use std::path::PathBuf;

pub(super) async fn upload(State(state): State<AppState>, mut multipart: Multipart) -> Response {
    let id = uuid();
    let directory = state.config.paths.uploads_dir.join(&id);
    if tokio::fs::create_dir_all(&directory).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let Some(field) = (match multipart.next_field().await {
        Ok(field) => field,
        Err(_) => return StatusCode::BAD_REQUEST.into_response(),
    }) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let filename = field
        .file_name()
        .map(Path::new)
        .and_then(|path| path.file_name())
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("source.epub")
        .to_owned();
    let bytes = match field.bytes().await {
        Ok(bytes) => bytes,
        Err(_) => return StatusCode::BAD_REQUEST.into_response(),
    };
    if tokio::fs::write(directory.join(&filename), &bytes)
        .await
        .is_err()
    {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    (
        StatusCode::OK,
        Json(UploadResponse {
            upload_id: id,
            file_name: filename,
            book_title: None,
            book_author: None,
            cover_url: None,
            cover_mime_type: None,
        }),
    )
        .into_response()
}

pub(super) async fn local_upload(
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
    Json(input): Json<LocalUpload>,
) -> Response {
    if !peer.ip().is_loopback() {
        return StatusCode::FORBIDDEN.into_response();
    }
    let raw_path = PathBuf::from(input.path);
    if !raw_path.is_absolute() {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let Ok(source) = raw_path.canonicalize() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !source.is_file() || !is_allowed_local_source(&source) {
        return StatusCode::FORBIDDEN.into_response();
    }
    if !matches!(
        source.extension().and_then(|value| value.to_str()),
        Some("epub" | "pdf" | "fb2" | "docx" | "cbz" | "cbr" | "mobi" | "prc" | "azw" | "azw3")
    ) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let filename = source
        .file_name()
        .and_then(|v| v.to_str())
        .unwrap_or("source.epub")
        .to_owned();
    let id = uuid();
    let directory = state.config.paths.uploads_dir.join(&id);
    if tokio::fs::create_dir_all(&directory).await.is_err()
        || tokio::fs::copy(&source, directory.join(&filename))
            .await
            .is_err()
    {
        return StatusCode::UNPROCESSABLE_ENTITY.into_response();
    }
    (
        StatusCode::OK,
        Json(UploadResponse {
            upload_id: id,
            file_name: filename,
            book_title: None,
            book_author: None,
            cover_url: None,
            cover_mime_type: None,
        }),
    )
        .into_response()
}

pub(super) fn is_allowed_local_source(source: &Path) -> bool {
    let mut roots = vec![PathBuf::from("/tmp"), PathBuf::from("/private/tmp")];
    if let Ok(cwd) = std::env::current_dir() {
        roots.push(cwd);
    }
    if let Ok(home) = std::env::var("HOME") {
        roots.push(PathBuf::from(home));
    }
    if Path::new("/var/folders").exists() {
        roots.push(PathBuf::from("/var/folders"));
    }
    if Path::new("/Volumes").exists() {
        roots.push(PathBuf::from("/Volumes"));
    }
    roots.iter().any(|root| source.starts_with(root))
}
