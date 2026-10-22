//! Job-scoped chapter/fulltext/output delivery and canonical path checks.
use super::http_input_paths::{find_job_input, safe_leaf};
use super::http_job_routes::is_terminal;
use super::http_runtime_state::{AppState, FulltextChapter, FulltextResponse};
use axum::extract::Path as AxumPath;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use converter_core::epub::parse_epub;
use converter_core::worker::OutputManifest;
use std::path::Path;
use std::path::PathBuf;
use tower_http::services::ServeFile;

pub(super) async fn resolved_output_path(
    root: &Path,
    job_id: &str,
    filename: &str,
) -> Result<PathBuf, StatusCode> {
    if !safe_leaf(job_id) || !safe_leaf(filename) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let root = tokio::fs::canonicalize(root)
        .await
        .map_err(|_| StatusCode::NOT_FOUND)?;
    let job = tokio::fs::canonicalize(root.join(job_id))
        .await
        .map_err(|_| StatusCode::NOT_FOUND)?;
    if job == root || !job.starts_with(&root) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let file = tokio::fs::canonicalize(job.join(filename))
        .await
        .map_err(|_| StatusCode::NOT_FOUND)?;
    if !file.starts_with(&job) {
        return Err(StatusCode::BAD_REQUEST);
    }
    Ok(file)
}

pub(super) async fn output(
    AxumPath((id, filename)): AxumPath<(String, String)>,
    State(state): State<AppState>,
    request: axum::extract::Request,
) -> Response {
    let path = match resolved_output_path(&state.config.paths.output_dir, &id, &filename).await {
        Ok(path) => path,
        Err(status) => return status.into_response(),
    };
    match ServeFile::new(path).try_call(request).await {
        Ok(response) => response.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}
pub(super) async fn chapters(
    AxumPath((id, index)): AxumPath<(String, u32)>,
    State(state): State<AppState>,
) -> Response {
    if !safe_leaf(&id) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let path =
        match resolved_output_path(&state.config.paths.output_dir, &id, "manifest.json").await {
            Ok(path) => path,
            Err(StatusCode::NOT_FOUND) => {
                return (
                    StatusCode::OK,
                    Json(serde_json::json!({"jobId":id,"chapterIndex":index,"chunks":[]})),
                )
                    .into_response()
            }
            Err(status) => return status.into_response(),
        };
    let Ok(bytes) = tokio::fs::read(path).await else {
        return (
            StatusCode::OK,
            Json(serde_json::json!({"jobId":id,"chapterIndex":index,"chunks":[]})),
        )
            .into_response();
    };
    let Ok(manifest) = serde_json::from_slice::<OutputManifest>(&bytes) else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let chunks = manifest.chapters.iter().find(|chapter| chapter.index == index as usize).map(|chapter| vec![serde_json::json!({"id":chapter.filename,"url":format!("/api/outputs/{id}/{}",chapter.filename)})]).unwrap_or_default();
    (StatusCode::OK, Json(serde_json::json!({"jobId":id,"chapterIndex":index,"baseUrl":format!("/api/streams/{id}/chapters/{index}"),"chunks":chunks}))).into_response()
}
pub(super) async fn fulltext(
    AxumPath(id): AxumPath<String>,
    State(state): State<AppState>,
) -> Response {
    let Some(job) = state.jobs.read().await.get(&id).cloned() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(input) = find_job_input(&state.config, &id).await else {
        return if is_terminal(&job.snapshot.state) {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::SERVICE_UNAVAILABLE
        }
        .into_response();
    };
    let Ok(file) = std::fs::File::open(input) else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let Ok(book) = parse_epub(std::io::BufReader::new(file)) else {
        return StatusCode::UNPROCESSABLE_ENTITY.into_response();
    };
    let chapters = book
        .chapters
        .into_iter()
        .enumerate()
        .map(|(position, chapter)| FulltextChapter {
            index: (position + 1) as u32,
            name: chapter.name,
            source_path: chapter.source_path,
            char_count: chapter.text.chars().count(),
            text: chapter.text,
        })
        .collect();
    (
        StatusCode::OK,
        Json(FulltextResponse {
            job_id: id,
            book_title: book.title,
            book_author: book.author,
            chapters,
        }),
    )
        .into_response()
}
