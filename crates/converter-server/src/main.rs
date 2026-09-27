use std::{
    collections::HashMap,
    convert::Infallible,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use axum::{
    extract::{Path as AxumPath, State},
    http::{header, HeaderMap, StatusCode},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{get, post},
    Json, Router,
};
use converter_core::{
    config::AppConfig,
    epub::parse_epub,
    worker::{ConversionRequest, ConversionWorker, OutputManifest, ProgressEvent},
};
use futures_util::stream::{self, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, RwLock};

const TERMINAL_STATES: &[&str] = &[
    "finished",
    "completed",
    "failed",
    "interrupted",
    "cancelled",
];

#[derive(Clone)]
struct AppState {
    config: AppConfig,
    jobs: Arc<RwLock<HashMap<String, Job>>>,
}
#[derive(Clone)]
struct Job {
    snapshot: JobSnapshot,
    events: broadcast::Sender<SseMessage>,
}
#[derive(Clone, Debug)]
enum SseMessage {
    Snapshot(JobSnapshot),
    Chapter(JobSnapshot),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JobSnapshot {
    job_id: String,
    state: String,
    events: Vec<String>,
    raw_log: Vec<String>,
    chapters_total: u32,
    chapters_completed: u32,
    progress_percent: f64,
    chapter_progress: Vec<ChapterProgress>,
    outputs: Vec<OutputAsset>,
    error: Option<String>,
    book_title: Option<String>,
    book_author: Option<String>,
    cover_url: Option<String>,
    cover_mime_type: Option<String>,
    log_url: Option<String>,
    engine: Option<String>,
    voice: Option<String>,
    language: Option<String>,
    formatting_cues: bool,
    ui_language: String,
    no_parallel: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChapterProgress {
    index: u32,
    name: String,
    status: String,
    engine: Option<String>,
    download_url: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OutputAsset {
    name: String,
    url: String,
    size_bytes: u64,
}
#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
}
#[derive(Debug, Serialize)]
struct MetadataResponse {
    status: &'static str,
    engine: String,
    expected_wpm: u32,
    persistent_root: String,
    cache_dir: String,
    output_dir: String,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UploadResponse {
    upload_id: String,
    file_name: String,
    book_title: Option<String>,
    book_author: Option<String>,
    cover_url: Option<String>,
    cover_mime_type: Option<String>,
}
#[derive(Debug, Deserialize, Default)]
struct LocalUpload {
    path: String,
}
#[derive(Debug, Deserialize, Default)]
struct CreateJob {
    upload_id: Option<String>,
    engine: Option<String>,
    voice: Option<String>,
    language: Option<String>,
    formatting_cues: Option<bool>,
    ui_language: Option<String>,
    no_parallel: Option<bool>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FulltextResponse {
    job_id: String,
    book_title: String,
    book_author: String,
    chapters: Vec<FulltextChapter>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FulltextChapter {
    index: u32,
    name: String,
    source_path: String,
    text: String,
    char_count: usize,
}

fn initial_job(id: String, f: &CreateJob) -> JobSnapshot {
    JobSnapshot {
        job_id: id,
        state: "queued".into(),
        events: vec!["Conversion queued".into()],
        raw_log: Vec::new(),
        chapters_total: 0,
        chapters_completed: 0,
        progress_percent: 0.0,
        chapter_progress: Vec::new(),
        outputs: Vec::new(),
        error: None,
        book_title: None,
        book_author: None,
        cover_url: None,
        cover_mime_type: None,
        log_url: None,
        engine: f.engine.clone(),
        voice: f.voice.clone(),
        language: f.language.clone(),
        formatting_cues: f.formatting_cues.unwrap_or(true),
        ui_language: if f.ui_language.as_deref() == Some("en") {
            "en"
        } else {
            "pt"
        }
        .into(),
        no_parallel: f.no_parallel.unwrap_or(false),
    }
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, Json(HealthResponse { status: "healthy" }))
}
async fn metadata(State(state): State<AppState>) -> impl IntoResponse {
    let paths = &state.config.paths;
    (
        StatusCode::OK,
        Json(MetadataResponse {
            status: "ok",
            engine: state.config.engine.clone(),
            expected_wpm: state.config.expected_wpm,
            persistent_root: paths.persistent_root.display().to_string(),
            cache_dir: paths.cache_dir.display().to_string(),
            output_dir: paths.output_dir.display().to_string(),
        }),
    )
}

async fn upload(State(state): State<AppState>, body: axum::body::Bytes) -> Response {
    let id = uuid();
    let directory = state.config.paths.uploads_dir.join(&id);
    if tokio::fs::create_dir_all(&directory).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let filename = "upload.bin".to_owned();
    let bytes = body.to_vec();

    let _ = tokio::fs::write(directory.join(&filename), &bytes).await;
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

async fn local_upload(State(state): State<AppState>, Json(input): Json<LocalUpload>) -> Response {
    let source = PathBuf::from(input.path);
    if !source.is_file() {
        return StatusCode::NOT_FOUND.into_response();
    }
    let filename = source
        .file_name()
        .and_then(|v| v.to_str())
        .unwrap_or("upload.bin")
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

async fn create_job(State(state): State<AppState>, Json(form): Json<CreateJob>) -> Response {
    let Some(upload_id) = form.upload_id.as_deref() else {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"uploadId is required"})),
        )
            .into_response();
    };
    let Some(input) = uploaded_file(&state.config, upload_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let id = uuid();
    let job_input_dir = state.config.paths.job_inputs_dir.join(&id);
    if tokio::fs::create_dir_all(&job_input_dir).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let input_name = input
        .file_name()
        .and_then(|v| v.to_str())
        .unwrap_or("source.epub")
        .to_owned();
    let input_copy = job_input_dir.join(&input_name);
    if tokio::fs::copy(&input, &input_copy).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let input = input_copy;
    let (sender, _) = broadcast::channel(64);
    let snapshot = initial_job(id.clone(), &form);
    state.jobs.write().await.insert(
        id.clone(),
        Job {
            snapshot,
            events: sender.clone(),
        },
    );
    let worker = match ConversionWorker::new(state.config.clone()) {
        Ok(worker) => worker,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let request = ConversionRequest {
        input,
        job_id: id.clone(),
        engine: form.engine.clone(),
        voice: form.voice.clone(),
        language: form.language.clone(),
        no_parallel: form.no_parallel.unwrap_or(false),
    };
    let jobs = state.jobs.clone();
    let response_id = id.clone();
    tokio::task::spawn_blocking(move || {
        let progress_jobs = jobs.clone();
        let progress_sender = sender.clone();
        let worker = worker.with_progress(Arc::new(move |event: ProgressEvent| {
            if let Ok(mut guard) = progress_jobs.try_write() {
                if let Some(job) = guard.get_mut(&event.job_id) {
                    job.snapshot.state = "running".into();
                    job.snapshot.chapters_total = event.chapters_total as u32;
                    job.snapshot.chapters_completed = event.chapters_completed as u32;
                    job.snapshot.progress_percent = event.percent;
                    job.snapshot.engine = event.engine.clone();
                    job.snapshot.events.push(event.message.clone());
                    job.snapshot.raw_log.push(event.message);
                    let _ = progress_sender.send(SseMessage::Chapter(job.snapshot.clone()));
                }
            }
        }));
        let result = worker.run(request);
        if let Ok(mut guard) = jobs.try_write() {
            if let Some(job) = guard.get_mut(&id) {
                match result {
                    Ok(manifest) => apply_manifest(&mut job.snapshot, &manifest),
                    Err(error) => {
                        job.snapshot.state = "failed".into();
                        job.snapshot.error = Some(error.to_string());
                        job.snapshot.events.push(error.to_string());
                    }
                }
                let _ = sender.send(SseMessage::Snapshot(job.snapshot.clone()));
            }
        }
    });
    (
        StatusCode::OK,
        Json(serde_json::json!({ "jobId": response_id })),
    )
        .into_response()
}

async fn status(AxumPath(id): AxumPath<String>, State(state): State<AppState>) -> Response {
    match state.jobs.read().await.get(&id) {
        Some(job) => (StatusCode::OK, Json(job.snapshot.clone())).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
async fn stream_job(AxumPath(id): AxumPath<String>, State(state): State<AppState>) -> Response {
    let (initial, receiver) = match state.jobs.read().await.get(&id) {
        Some(job) => (job.snapshot.clone(), job.events.subscribe()),
        None => return StatusCode::NOT_FOUND.into_response(),
    };
    let first =
        stream::once(async move { Ok::<Event, Infallible>(snapshot_event(&initial, false)) });
    let updates = stream::unfold((receiver, false), |(mut receiver, done)| async move {
        if done {
            return None;
        }
        match receiver.recv().await {
            Ok(SseMessage::Snapshot(snapshot)) => {
                let terminal = is_terminal(&snapshot.state);
                Some((Ok(snapshot_event(&snapshot, false)), (receiver, terminal)))
            }
            Ok(SseMessage::Chapter(snapshot)) => {
                Some((Ok(snapshot_event(&snapshot, true)), (receiver, false)))
            }
            Err(broadcast::error::RecvError::Lagged(_)) => Some((
                Ok(Event::default().comment("missed updates")),
                (receiver, false),
            )),
            Err(broadcast::error::RecvError::Closed) => None,
        }
    });
    Sse::new(first.chain(updates))
        .keep_alive(
            KeepAlive::new()
                .interval(Duration::from_secs(15))
                .text("heartbeat"),
        )
        .into_response()
}
async fn cancel(AxumPath(id): AxumPath<String>, State(state): State<AppState>) -> Response {
    match state.jobs.write().await.get_mut(&id) {
        Some(job) if is_terminal(&job.snapshot.state) => (
            StatusCode::OK,
            Json(serde_json::json!({"status": job.snapshot.state})),
        )
            .into_response(),
        Some(job) => {
            job.snapshot.state = if job.snapshot.state == "queued" {
                "cancelled"
            } else {
                "cancelling"
            }
            .into();
            let _ = job.events.send(SseMessage::Snapshot(job.snapshot.clone()));
            (
                StatusCode::OK,
                Json(serde_json::json!({"status": job.snapshot.state})),
            )
                .into_response()
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
async fn resume_job(AxumPath(id): AxumPath<String>, State(state): State<AppState>) -> Response {
    match state.jobs.write().await.get_mut(&id) {
        Some(job) if job.snapshot.state == "finished" || job.snapshot.state == "completed" => (
            StatusCode::OK,
            Json(serde_json::json!({"status":"finished"})),
        )
            .into_response(),
        Some(job) => {
            job.snapshot.state = "queued".into();
            let _ = job.events.send(SseMessage::Snapshot(job.snapshot.clone()));
            (StatusCode::OK, Json(serde_json::json!({"status":"queued"}))).into_response()
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
async fn log(AxumPath(id): AxumPath<String>, State(state): State<AppState>) -> Response {
    let Some(job) = state.jobs.read().await.get(&id).cloned() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let body = if job.snapshot.raw_log.is_empty() {
        job.snapshot.events.join("\n")
    } else {
        job.snapshot.raw_log.join("\n")
    };
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        "text/plain; charset=utf-8".parse().unwrap(),
    );
    (StatusCode::OK, headers, body).into_response()
}
async fn output(
    AxumPath((id, filename)): AxumPath<(String, String)>,
    State(state): State<AppState>,
) -> Response {
    if !safe_leaf(&filename) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    match tokio::fs::read(state.config.paths.output_dir.join(&id).join(&filename)).await {
        Ok(bytes) => (StatusCode::OK, bytes).into_response(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            StatusCode::NOT_FOUND.into_response()
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}
async fn chapters(
    AxumPath((id, index)): AxumPath<(String, u32)>,
    State(state): State<AppState>,
) -> Response {
    let path = state
        .config
        .paths
        .output_dir
        .join(&id)
        .join("manifest.json");
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
async fn fulltext(AxumPath(id): AxumPath<String>, State(state): State<AppState>) -> Response {
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

fn app(config: AppConfig) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/api/metadata", get(metadata))
        .route("/api/uploads", post(upload))
        .route("/api/uploads/local", post(local_upload))
        .route("/api/convert", post(create_job))
        .route("/api/jobs/resumable", get(resumable_jobs))
        .route("/api/jobs/recent", get(recent_jobs))
        .route("/api/jobs/{id}", get(status))
        .route("/api/jobs/{id}/stream", get(stream_job))
        .route("/api/jobs/{id}/cancel", post(cancel))
        .route("/api/jobs/{id}/resume", post(resume_job))
        .route("/api/jobs/{id}/log", get(log))
        .route("/api/jobs/{id}/fulltext", get(fulltext))
        .route("/api/outputs/{id}/{file}", get(output))
        .route("/api/streams/{id}/chapters/{index}", get(chapters))
        .with_state(AppState {
            config,
            jobs: Arc::new(RwLock::new(HashMap::new())),
        })
}
async fn resumable_jobs(State(state): State<AppState>) -> Response {
    let jobs = state
        .jobs
        .read()
        .await
        .values()
        .filter(|job| {
            matches!(
                job.snapshot.state.as_str(),
                "queued" | "running" | "cancelling"
            )
        })
        .map(|job| job.snapshot.clone())
        .collect::<Vec<_>>();
    let count = jobs.len();
    (
        StatusCode::OK,
        Json(serde_json::json!({"resumableJobs":jobs,"count":count})),
    )
        .into_response()
}
async fn recent_jobs(State(state): State<AppState>) -> Response {
    let jobs = state
        .jobs
        .read()
        .await
        .values()
        .map(|job| job.snapshot.clone())
        .collect::<Vec<_>>();
    let count = jobs.len();
    (
        StatusCode::OK,
        Json(serde_json::json!({"jobs":jobs,"count":count})),
    )
        .into_response()
}
fn snapshot_event(snapshot: &JobSnapshot, chapter: bool) -> Event {
    let event = Event::default().data(serde_json::to_string(snapshot).unwrap_or_default());
    if chapter {
        event.event("chapter_update")
    } else {
        event
    }
}
fn is_terminal(state: &str) -> bool {
    TERMINAL_STATES.contains(&state)
}
#[allow(dead_code)]
fn inspect_book(path: &Path) -> (Option<String>, Option<String>) {
    std::fs::File::open(path)
        .ok()
        .and_then(|file| parse_epub(std::io::BufReader::new(file)).ok())
        .map(|book| (Some(book.title), Some(book.author)))
        .unwrap_or((None, None))
}
async fn uploaded_file(config: &AppConfig, upload_id: &str) -> Option<PathBuf> {
    if !safe_leaf(upload_id) {
        return None;
    }
    let mut entries = tokio::fs::read_dir(config.paths.uploads_dir.join(upload_id))
        .await
        .ok()?;
    while let Ok(Some(entry)) = entries.next_entry().await {
        if entry.file_type().await.ok()?.is_file() {
            return Some(entry.path());
        }
    }
    None
}
async fn find_job_input(config: &AppConfig, job_id: &str) -> Option<PathBuf> {
    if !safe_leaf(job_id) {
        return None;
    }
    let mut entries = tokio::fs::read_dir(config.paths.job_inputs_dir.join(job_id))
        .await
        .ok()?;
    while let Ok(Some(entry)) = entries.next_entry().await {
        if entry.file_type().await.ok()?.is_file() {
            return Some(entry.path());
        }
    }
    None
}
fn apply_manifest(snapshot: &mut JobSnapshot, manifest: &OutputManifest) {
    snapshot.state = "finished".into();
    snapshot.book_title = Some(manifest.title.clone());
    snapshot.book_author = Some(manifest.author.clone());
    snapshot.chapters_total = manifest.chapters.len() as u32;
    snapshot.chapters_completed = snapshot.chapters_total;
    snapshot.progress_percent = 100.0;
    snapshot.chapter_progress = manifest
        .chapters
        .iter()
        .map(|chapter| ChapterProgress {
            index: chapter.index as u32,
            name: chapter.title.clone(),
            status: "finished".into(),
            engine: snapshot.engine.clone(),
            download_url: Some(format!(
                "/api/outputs/{}/{}",
                snapshot.job_id, chapter.filename
            )),
        })
        .collect();
    snapshot.outputs = manifest
        .chapters
        .iter()
        .map(|chapter| OutputAsset {
            name: chapter.filename.clone(),
            url: format!("/api/outputs/{}/{}", snapshot.job_id, chapter.filename),
            size_bytes: 0,
        })
        .collect();
    snapshot.events.push("Conversion finished".into());
}
fn safe_leaf(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && Path::new(value).file_name().and_then(|v| v.to_str()) == Some(value)
}
fn uuid() -> String {
    format!(
        "{:032x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    )
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = AppConfig::from_env();
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port = std::env::var("PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(7860);
    let address: SocketAddr = format!("{host}:{port}").parse()?;
    tokio::fs::create_dir_all(&config.paths.uploads_dir).await?;
    tokio::fs::create_dir_all(&config.paths.job_inputs_dir).await?;
    tokio::fs::create_dir_all(&config.paths.output_dir).await?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    println!("converter-server listening on {address}");
    axum::serve(listener, app(config)).await?;
    Ok(())
}
