use std::{
    collections::HashMap,
    convert::Infallible,
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use axum::{
    extract::{ConnectInfo, DefaultBodyLimit, Multipart, Path as AxumPath, State},
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
use tower_http::services::{ServeDir, ServeFile};

// Keep a concrete server-side ceiling above normal EPUB sizes while preventing unbounded request bodies.
const MAX_UPLOAD_BYTES: usize = 100 * 1024 * 1024;
const API_CONTRACT_VERSION: &str = "1";

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
    cancellation: converter_core::piper::CancellationToken,
    worker_active: bool,
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
    contract_version: &'static str,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ContractResponse {
    version: &'static str,
    backend: &'static str,
    capabilities: Vec<&'static str>,
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

fn snapshot_path(config: &AppConfig, job_id: &str) -> PathBuf {
    config
        .paths
        .jobs_dir
        .join(format!("{job_id}.snapshot.json"))
}

fn persist_snapshot(config: &AppConfig, snapshot: &JobSnapshot) -> std::io::Result<()> {
    fs::create_dir_all(&config.paths.jobs_dir)?;
    let target = snapshot_path(config, &snapshot.job_id);
    let temporary = target.with_extension(format!("tmp-{}", std::process::id()));
    let bytes = serde_json::to_vec_pretty(snapshot)
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, target)
}

fn load_snapshots(config: &AppConfig) -> HashMap<String, Job> {
    let mut jobs = HashMap::new();
    let Ok(entries) = fs::read_dir(&config.paths.jobs_dir) else {
        return jobs;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        if !name.ends_with(".snapshot.json") {
            continue;
        }
        let Ok(bytes) = fs::read(path) else {
            continue;
        };
        let Ok(mut snapshot) = serde_json::from_slice::<JobSnapshot>(&bytes) else {
            continue;
        };
        if matches!(snapshot.state.as_str(), "queued" | "running" | "cancelling") {
            snapshot.state = "interrupted".into();
            snapshot.error = Some("Server restarted before the conversion completed".into());
            snapshot
                .events
                .push("Conversion interrupted by server restart".into());
            let _ = persist_snapshot(config, &snapshot);
        }
        let (events, _) = broadcast::channel(64);
        jobs.insert(
            snapshot.job_id.clone(),
            Job {
                snapshot,
                events,
                cancellation: converter_core::piper::CancellationToken::default(),
                worker_active: false,
            },
        );
    }
    jobs
}

async fn health() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(HealthResponse {
            status: "healthy",
            contract_version: API_CONTRACT_VERSION,
        }),
    )
}
async fn contract() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(ContractResponse {
            version: API_CONTRACT_VERSION,
            backend: "rust",
            capabilities: vec!["uploads", "jobs", "sse", "epub", "edge", "piper"],
        }),
    )
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

async fn upload(State(state): State<AppState>, mut multipart: Multipart) -> Response {
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

async fn local_upload(
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

fn is_allowed_local_source(source: &Path) -> bool {
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
            cancellation: converter_core::piper::CancellationToken::default(),
            worker_active: true,
        },
    );
    if let Some(job) = state.jobs.read().await.get(&id) {
        let _ = persist_snapshot(&state.config, &job.snapshot);
    }
    let cancellation = state
        .jobs
        .read()
        .await
        .get(&id)
        .map(|job| job.cancellation.clone())
        .expect("job inserted before worker starts");
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
        chapter_indices: None,
        no_parallel: form.no_parallel.unwrap_or(false),
    };
    let response_id = id.clone();
    start_worker(state, worker, request, sender, cancellation, false);
    (
        StatusCode::OK,
        Json(serde_json::json!({ "jobId": response_id })),
    )
        .into_response()
}

fn start_worker(
    state: AppState,
    worker: ConversionWorker,
    request: ConversionRequest,
    sender: broadcast::Sender<SseMessage>,
    cancellation: converter_core::piper::CancellationToken,
    resuming: bool,
) {
    let id = request.job_id.clone();
    let jobs = state.jobs.clone();
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
            } else {
                let mut guard = progress_jobs.blocking_write();
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
        let worker = worker.with_cancellation(cancellation);
        let result = if resuming {
            worker.resume(request)
        } else {
            worker.run(request)
        };
        let mut guard = jobs.blocking_write();
        if let Some(job) = guard.get_mut(&id) {
            job.worker_active = false;
            match result {
                Ok(manifest) => {
                    apply_manifest(&mut job.snapshot, &manifest, &state.config.paths.output_dir)
                }
                Err(error) => {
                    job.snapshot.state =
                        if matches!(error, converter_core::worker::WorkerError::Cancelled) {
                            "cancelled".into()
                        } else {
                            "failed".into()
                        };
                    job.snapshot.error = Some(error.to_string());
                    job.snapshot.events.push(error.to_string());
                }
            }
            let _ = persist_snapshot(&state.config, &job.snapshot);
            let _ = sender.send(SseMessage::Snapshot(job.snapshot.clone()));
        }
    });
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
    let initially_terminal = is_terminal(&initial.state);
    let first =
        stream::once(async move { Ok::<Event, Infallible>(snapshot_event(&initial, false)) });
    let updates = stream::unfold(
        (receiver, initially_terminal),
        |(mut receiver, done)| async move {
            if done {
                return None;
            }
            match receiver.recv().await {
                Ok(SseMessage::Snapshot(snapshot)) => {
                    let terminal = is_terminal(&snapshot.state);
                    Some((Ok(snapshot_event(&snapshot, false)), (receiver, terminal)))
                }
                Ok(SseMessage::Chapter(snapshot)) => {
                    let terminal = is_terminal(&snapshot.state);
                    Some((Ok(snapshot_event(&snapshot, true)), (receiver, terminal)))
                }
                Err(broadcast::error::RecvError::Lagged(_)) => Some((
                    Ok(Event::default().comment("missed updates")),
                    (receiver, false),
                )),
                Err(broadcast::error::RecvError::Closed) => None,
            }
        },
    );
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
            let mut snapshot = job.snapshot.clone();
            snapshot.state = if snapshot.state == "queued" {
                "cancelled"
            } else {
                "cancelling"
            }
            .into();
            if let Err(error) = persist_snapshot(&state.config, &snapshot) {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("Could not persist cancellation: {error}"),
                )
                    .into_response();
            }
            job.snapshot = snapshot;
            job.cancellation.cancel();
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
    if !safe_leaf(&id) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let mut jobs = state.jobs.write().await;
    let Some(job) = jobs.get_mut(&id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if matches!(
        job.snapshot.state.as_str(),
        "queued" | "running" | "finished" | "completed"
    ) {
        return (
            StatusCode::OK,
            Json(serde_json::json!({"status": job.snapshot.state})),
        )
            .into_response();
    }
    if job.worker_active || job.snapshot.state == "cancelling" {
        return StatusCode::CONFLICT.into_response();
    }
    let Ok(mut entries) = tokio::fs::read_dir(state.config.paths.job_inputs_dir.join(&id)).await
    else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let mut input = None;
    while let Ok(Some(entry)) = entries.next_entry().await {
        if entry.file_type().await.is_ok_and(|kind| kind.is_file()) {
            input = Some(entry.path());
            break;
        }
    }
    let Some(input) = input else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let worker = match ConversionWorker::new(state.config.clone()) {
        Ok(worker) => worker,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let mut snapshot = job.snapshot.clone();
    snapshot.state = "queued".into();
    snapshot.error = None;
    if persist_snapshot(&state.config, &snapshot).is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let request = ConversionRequest {
        input,
        job_id: id,
        engine: snapshot.engine.clone(),
        voice: snapshot.voice.clone(),
        language: snapshot.language.clone(),
        chapter_indices: None,
        no_parallel: snapshot.no_parallel,
    };
    job.snapshot = snapshot;
    job.cancellation = Default::default();
    job.worker_active = true;
    let sender = job.events.clone();
    let cancellation = job.cancellation.clone();
    let _ = sender.send(SseMessage::Snapshot(job.snapshot.clone()));
    drop(jobs);
    start_worker(state, worker, request, sender, cancellation, true);
    (
        StatusCode::OK,
        Json(serde_json::json!({"status": "queued"})),
    )
        .into_response()
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
    request: axum::extract::Request,
) -> Response {
    if !safe_leaf(&id) || !safe_leaf(&filename) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    match ServeFile::new(state.config.paths.output_dir.join(&id).join(&filename))
        .try_call(request)
        .await
    {
        Ok(response) => response.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}
async fn chapters(
    AxumPath((id, index)): AxumPath<(String, u32)>,
    State(state): State<AppState>,
) -> Response {
    if !safe_leaf(&id) {
        return StatusCode::BAD_REQUEST.into_response();
    }
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
    let recovered_jobs = load_snapshots(&config);
    Router::new()
        .route("/health", get(health))
        .route("/api/health", get(health))
        .route("/api/contract", get(contract))
        .route("/api/metadata", get(metadata))
        .route(
            "/api/uploads",
            post(upload).layer(DefaultBodyLimit::max(MAX_UPLOAD_BYTES)),
        )
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
        .fallback_service(ServeDir::new("web/dist").append_index_html_on_directories(true))
        .with_state(AppState {
            config,
            jobs: Arc::new(RwLock::new(recovered_jobs)),
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
                "queued" | "running" | "cancelling" | "interrupted"
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
fn apply_manifest(snapshot: &mut JobSnapshot, manifest: &OutputManifest, output_dir: &Path) {
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
            size_bytes: std::fs::metadata(
                output_dir.join(&snapshot.job_id).join(&chapter.filename),
            )
            .map(|metadata| metadata.len())
            .unwrap_or(0),
        })
        .collect();
    if safe_leaf(&snapshot.job_id) && safe_leaf(&manifest.archive) {
        let archive = output_dir.join(&snapshot.job_id).join(&manifest.archive);
        if let Ok(metadata) = std::fs::metadata(archive) {
            if metadata.is_file() && metadata.len() > 0 {
                snapshot.outputs.push(OutputAsset {
                    name: manifest.archive.clone(),
                    url: format!("/api/outputs/{}/{}", snapshot.job_id, manifest.archive),
                    size_bytes: metadata.len(),
                });
            }
        }
    }
    snapshot.events.push("Conversion finished".into());
}
fn safe_leaf(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && Path::new(value).file_name().and_then(|v| v.to_str()) == Some(value)
}
fn uuid() -> String {
    let mut bytes = [0u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        let fallback = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        bytes.copy_from_slice(&fallback.to_le_bytes());
    }
    // UUID v4 layout: random identifier with the version/variant bits set.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        u32::from_be_bytes(bytes[0..4].try_into().unwrap()),
        u16::from_be_bytes(bytes[4..6].try_into().unwrap()),
        u16::from_be_bytes(bytes[6..8].try_into().unwrap()),
        u16::from_be_bytes(bytes[8..10].try_into().unwrap()),
        u64::from_be_bytes([
            0, 0, bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ]),
    )
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = AppConfig::from_env();
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port = std::env::var("PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(8000);
    let address: SocketAddr = format!("{host}:{port}").parse()?;
    tokio::fs::create_dir_all(&config.paths.uploads_dir).await?;
    tokio::fs::create_dir_all(&config.paths.job_inputs_dir).await?;
    tokio::fs::create_dir_all(&config.paths.output_dir).await?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    println!("converter-server listening on {address}");
    axum::serve(
        listener,
        app(config).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn active_sse_stays_open_until_a_terminal_chapter_event() {
        let root = TestRoot::new();
        let state = root.state();
        let snapshot = initial_job("active-job".into(), &CreateJob::default());
        let (events, _) = broadcast::channel(8);
        state.jobs.write().await.insert(
            "active-job".into(),
            Job {
                snapshot: snapshot.clone(),
                events: events.clone(),
                cancellation: Default::default(),
                worker_active: false,
            },
        );
        let response = stream_job(AxumPath("active-job".into()), State(state.clone())).await;
        let mut stream = response.into_body().into_data_stream();
        assert!(stream.next().await.unwrap().is_ok());
        assert!(
            tokio::time::timeout(Duration::from_millis(20), stream.next())
                .await
                .is_err()
        );
        let mut terminal = snapshot;
        terminal.state = "cancelled".into();
        events.send(SseMessage::Chapter(terminal)).unwrap();
        let event = tokio::time::timeout(Duration::from_millis(100), stream.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(String::from_utf8_lossy(&event).contains("cancelled"));
        assert!(matches!(
            tokio::time::timeout(Duration::from_millis(100), stream.next()).await,
            Ok(None)
        ));
    }

    #[tokio::test]
    async fn initially_finished_job_emits_one_snapshot_then_closes_sse() {
        let root = TestRoot::new();
        let state = root.state();
        let mut snapshot = initial_job("finished-job".into(), &CreateJob::default());
        snapshot.state = "finished".into();
        let (events, _) = broadcast::channel(8);
        state.jobs.write().await.insert(
            "finished-job".into(),
            Job {
                snapshot,
                events,
                cancellation: Default::default(),
                worker_active: false,
            },
        );
        let response = stream_job(AxumPath("finished-job".into()), State(state.clone())).await;
        assert_eq!(response.status(), StatusCode::OK);
        let mut stream = response.into_body().into_data_stream();
        let initial = stream.next().await.unwrap().unwrap();
        assert!(String::from_utf8_lossy(&initial).contains("finished"));
        let closed = tokio::time::timeout(Duration::from_millis(100), stream.next()).await;
        assert!(
            matches!(closed, Ok(None)),
            "a terminal initial snapshot must close SSE"
        );
    }

    #[tokio::test]
    async fn restarted_jobs_are_discoverable_through_the_resumable_api() {
        let root = TestRoot::new();
        let state = root.state();
        let queued = initial_job("restart-job".into(), &CreateJob::default());
        persist_snapshot(&state.config, &queued).unwrap();
        let mut completed = initial_job("complete-job".into(), &CreateJob::default());
        completed.state = "completed".into();
        persist_snapshot(&state.config, &completed).unwrap();
        let response = http_fixture_request(
            state.config,
            b"GET /api/jobs/resumable HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        let body = response.split_once("\r\n\r\n").unwrap().1;
        let value: serde_json::Value = serde_json::from_str(body).unwrap();
        assert_eq!(value["count"], 1);
        assert_eq!(value["resumableJobs"][0]["jobId"], "restart-job");
        assert_eq!(value["resumableJobs"][0]["state"], "interrupted");
    }

    #[tokio::test]
    async fn resume_executes_the_worker_with_a_fresh_cancellation_token() {
        let root = TestRoot::new();
        let state = root.state();
        let input_dir = state.config.paths.job_inputs_dir.join("resume-job");
        std::fs::create_dir_all(&input_dir).unwrap();
        std::fs::write(input_dir.join("source.epub"), b"invalid epub fixture").unwrap();
        let previous = ConversionWorker::new(state.config.clone()).unwrap();
        let previous_result = previous.run(ConversionRequest {
            input: input_dir.join("source.epub"),
            job_id: "resume-job".into(),
            engine: None,
            voice: None,
            language: None,
            chapter_indices: None,
            no_parallel: false,
        });
        assert!(matches!(
            previous_result,
            Err(converter_core::worker::WorkerError::Epub(_))
        ));
        let mut snapshot = initial_job("resume-job".into(), &CreateJob::default());
        snapshot.state = "cancelled".into();
        snapshot.error = Some("Previous attempt cancelled".into());
        let cancellation = converter_core::piper::CancellationToken::default();
        cancellation.cancel();
        let (events, mut receiver) = broadcast::channel(8);
        state.jobs.write().await.insert(
            snapshot.job_id.clone(),
            Job {
                snapshot,
                events,
                cancellation,
                worker_active: false,
            },
        );
        let response = resume_job(AxumPath("resume-job".into()), State(state.clone())).await;
        assert_eq!(response.status(), StatusCode::OK);
        let initial = receiver.recv().await.unwrap();
        assert!(
            matches!(initial, SseMessage::Snapshot(ref s) if s.state == "queued" && s.error.is_none())
        );
        let terminal = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if let SseMessage::Snapshot(snapshot) = receiver.recv().await.unwrap() {
                    if is_terminal(&snapshot.state) {
                        break snapshot;
                    }
                }
            }
        })
        .await
        .expect("resume must launch the actual conversion worker");
        assert_eq!(terminal.state, "failed", "invalid EPUB must reach parsing rather than remain queued or reuse the cancelled token");
        assert!(terminal
            .error
            .as_deref()
            .unwrap()
            .starts_with("EPUB error:"));
        assert!(!state.jobs.read().await["resume-job"]
            .cancellation
            .is_cancelled());
        assert_eq!(
            load_snapshots(&state.config)["resume-job"].snapshot.state,
            "failed"
        );
    }

    #[tokio::test]
    async fn resume_missing_input_keeps_the_terminal_snapshot() {
        let root = TestRoot::new();
        let state = root.state();
        let mut snapshot = initial_job("missing-input".into(), &CreateJob::default());
        snapshot.state = "interrupted".into();
        let (events, mut receiver) = broadcast::channel(8);
        state.jobs.write().await.insert(
            snapshot.job_id.clone(),
            Job {
                snapshot,
                events,
                cancellation: Default::default(),
                worker_active: false,
            },
        );
        let response = resume_job(AxumPath("missing-input".into()), State(state.clone())).await;
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert_eq!(
            state.jobs.read().await["missing-input"].snapshot.state,
            "interrupted"
        );
        assert!(matches!(
            receiver.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn resume_waits_for_the_previous_worker_to_stop() {
        let root = TestRoot::new();
        let state = root.state();
        let mut snapshot = initial_job("cancelled-job".into(), &CreateJob::default());
        snapshot.state = "cancelled".into();
        let (events, mut receiver) = broadcast::channel(8);
        state.jobs.write().await.insert(
            snapshot.job_id.clone(),
            Job {
                snapshot,
                events,
                cancellation: Default::default(),
                worker_active: true,
            },
        );
        let response = resume_job(AxumPath("cancelled-job".into()), State(state.clone())).await;
        assert_eq!(response.status(), StatusCode::CONFLICT);
        assert_eq!(
            state.jobs.read().await["cancelled-job"].snapshot.state,
            "cancelled"
        );
        assert!(matches!(
            receiver.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn resume_running_job_does_not_reset_it() {
        let root = TestRoot::new();
        let state = root.state();
        let mut snapshot = initial_job("running-job".into(), &CreateJob::default());
        snapshot.state = "running".into();
        let (events, mut receiver) = broadcast::channel(8);
        state.jobs.write().await.insert(
            snapshot.job_id.clone(),
            Job {
                snapshot,
                events,
                cancellation: Default::default(),
                worker_active: false,
            },
        );
        let response = resume_job(AxumPath("running-job".into()), State(state.clone())).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            state.jobs.read().await["running-job"].snapshot.state,
            "running"
        );
        assert!(matches!(
            receiver.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn queued_cancellation_survives_snapshot_recovery() {
        let root = TestRoot::new();
        let state = root.state();
        let snapshot = initial_job("cancel-job".into(), &CreateJob::default());
        persist_snapshot(&state.config, &snapshot).unwrap();
        let (events, _) = broadcast::channel(8);
        state.jobs.write().await.insert(
            snapshot.job_id.clone(),
            Job {
                snapshot,
                events,
                cancellation: Default::default(),
                worker_active: false,
            },
        );
        let response = cancel(AxumPath("cancel-job".into()), State(state.clone())).await;
        assert_eq!(response.status(), StatusCode::OK);
        let recovered = load_snapshots(&state.config);
        assert_eq!(recovered["cancel-job"].snapshot.state, "cancelled");
        assert!(recovered["cancel-job"].snapshot.error.is_none());
    }

    #[tokio::test]
    async fn cancellation_persistence_failure_does_not_report_success() {
        let root = TestRoot::new();
        let state = root.state();
        std::fs::create_dir_all(state.config.paths.jobs_dir.parent().unwrap()).unwrap();
        std::fs::write(&state.config.paths.jobs_dir, b"not a directory").unwrap();
        let snapshot = initial_job("cancel-job".into(), &CreateJob::default());
        let (events, mut receiver) = broadcast::channel(8);
        state.jobs.write().await.insert(
            snapshot.job_id.clone(),
            Job {
                snapshot,
                events,
                cancellation: Default::default(),
                worker_active: false,
            },
        );
        let response = cancel(AxumPath("cancel-job".into()), State(state.clone())).await;
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let jobs = state.jobs.read().await;
        assert_eq!(jobs["cancel-job"].snapshot.state, "queued");
        assert!(!jobs["cancel-job"].cancellation.is_cancelled());
        assert!(matches!(
            receiver.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn large_archive_download_is_streamed_in_bounded_chunks() {
        let root = TestRoot::new();
        let state = root.state();
        let job = state.config.paths.output_dir.join("large-job");
        std::fs::create_dir_all(&job).unwrap();
        let size = 4 * 1024 * 1024;
        std::fs::File::create(job.join("book.zip"))
            .unwrap()
            .set_len(size)
            .unwrap();
        let response = output(
            AxumPath(("large-job".into(), "book.zip".into())),
            State(state),
            request("GET"),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[header::CONTENT_LENGTH], size.to_string());
        assert_eq!(response.headers()[header::CONTENT_TYPE], "application/zip");
        let mut stream = response.into_body().into_data_stream();
        let mut total = 0;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.unwrap();
            assert!(
                chunk.len() <= 64 * 1024,
                "download chunk must remain bounded"
            );
            total += chunk.len() as u64;
        }
        assert_eq!(total, size);
    }

    #[tokio::test]
    async fn head_and_unsatisfiable_range_keep_http_semantics() {
        let root = TestRoot::new();
        let state = root.state();
        let job = state.config.paths.output_dir.join("range-job");
        std::fs::create_dir_all(&job).unwrap();
        std::fs::write(job.join("chapter.mp3"), b"0123456789").unwrap();
        let head = output(
            AxumPath(("range-job".into(), "chapter.mp3".into())),
            State(state.clone()),
            request("HEAD"),
        )
        .await;
        assert_eq!(head.status(), StatusCode::OK);
        assert_eq!(head.headers()[header::CONTENT_LENGTH], "10");
        assert_eq!(head.headers()[header::CONTENT_TYPE], "audio/mpeg");
        assert!(axum::body::to_bytes(head.into_body(), 100)
            .await
            .unwrap()
            .is_empty());
        let mut range = request("GET");
        range
            .headers_mut()
            .insert(header::RANGE, "bytes=20-30".parse().unwrap());
        let response = output(
            AxumPath(("range-job".into(), "chapter.mp3".into())),
            State(state.clone()),
            range,
        )
        .await;
        assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
        assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes */10");
        let missing = output(
            AxumPath(("range-job".into(), "missing.mp3".into())),
            State(state),
            request("GET"),
        )
        .await;
        assert_eq!(missing.status(), StatusCode::NOT_FOUND);
    }

    fn request(method: &str) -> axum::extract::Request {
        axum::http::Request::builder()
            .method(method)
            .uri("/")
            .body(axum::body::Body::empty())
            .unwrap()
    }

    async fn http_fixture_request(config: AppConfig, request: &'static [u8]) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app(config)).await.unwrap();
        });
        let response = tokio::task::spawn_blocking(move || {
            use std::io::{Read, Write};
            let mut client = std::net::TcpStream::connect(address).unwrap();
            client
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            client.write_all(request).unwrap();
            let mut bytes = Vec::new();
            client.read_to_end(&mut bytes).unwrap();
            String::from_utf8(bytes).unwrap()
        })
        .await
        .unwrap();
        server.abort();
        response
    }

    #[tokio::test]
    async fn audio_download_serves_requested_byte_range() {
        let root = TestRoot::new();
        let state = root.state();
        let job = state.config.paths.output_dir.join("range-job");
        std::fs::create_dir_all(&job).unwrap();
        std::fs::write(job.join("chapter.mp3"), b"0123456789").unwrap();
        let response = http_fixture_request(state.config, b"GET /api/outputs/range-job/chapter.mp3 HTTP/1.1\r\nHost: localhost\r\nRange: bytes=2-5\r\nConnection: close\r\n\r\n").await;
        assert!(response.starts_with("HTTP/1.1 206"), "{response}");
        assert!(response
            .to_ascii_lowercase()
            .contains("content-range: bytes 2-5/10"));
        assert!(response.ends_with("2345"));
    }

    #[test]
    fn finished_snapshot_exposes_the_complete_archive() {
        let root = TestRoot::new();
        let state = root.state();
        let job_dir = state.config.paths.output_dir.join("archive-job");
        std::fs::create_dir_all(&job_dir).unwrap();
        std::fs::write(job_dir.join("book.zip"), b"archive fixture").unwrap();
        let manifest = OutputManifest {
            job_id: "archive-job".into(),
            title: "Book".into(),
            author: "Author".into(),
            chapters: Vec::new(),
            archive: "book.zip".into(),
            cover: None,
        };
        let mut snapshot = initial_job("archive-job".into(), &CreateJob::default());
        apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
        let archive = snapshot
            .outputs
            .iter()
            .find(|asset| asset.name == "book.zip")
            .expect("completed archives must be advertised for download");
        assert_eq!(archive.url, "/api/outputs/archive-job/book.zip");
        assert_eq!(archive.size_bytes, 15);
        let value = serde_json::to_value(&snapshot).unwrap();
        assert_eq!(value["outputs"][0]["sizeBytes"], 15);
        std::fs::remove_file(job_dir.join("book.zip")).unwrap();
        apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
        assert!(snapshot.outputs.is_empty());
        std::fs::write(job_dir.join("book.zip"), []).unwrap();
        apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
        assert!(snapshot.outputs.is_empty());
        std::fs::remove_file(job_dir.join("book.zip")).unwrap();
        std::fs::create_dir(job_dir.join("book.zip")).unwrap();
        apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
        assert!(snapshot.outputs.is_empty());
    }

    #[test]
    fn manifest_archive_cannot_escape_the_job_directory() {
        let root = TestRoot::new();
        let state = root.state();
        std::fs::create_dir_all(&state.config.paths.output_dir).unwrap();
        std::fs::write(
            state.config.paths.output_dir.join("outside.zip"),
            b"outside archive",
        )
        .unwrap();
        let manifest = OutputManifest {
            job_id: "archive-job".into(),
            title: "Book".into(),
            author: "Author".into(),
            chapters: Vec::new(),
            archive: "../outside.zip".into(),
            cover: None,
        };
        let mut snapshot = initial_job("archive-job".into(), &CreateJob::default());
        apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
        assert!(snapshot.outputs.is_empty());
    }

    #[tokio::test]
    async fn advertised_archive_can_be_downloaded() {
        let root = TestRoot::new();
        let state = root.state();
        let job_dir = state.config.paths.output_dir.join("archive-job");
        std::fs::create_dir_all(&job_dir).unwrap();
        std::fs::write(job_dir.join("book.zip"), b"download archive").unwrap();
        let manifest = OutputManifest {
            job_id: "archive-job".into(),
            title: "Book".into(),
            author: "Author".into(),
            chapters: Vec::new(),
            archive: "book.zip".into(),
            cover: None,
        };
        let mut snapshot = initial_job("archive-job".into(), &CreateJob::default());
        apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
        let archive = &snapshot.outputs[0];
        let response = output(
            AxumPath((snapshot.job_id.clone(), archive.name.clone())),
            State(state),
            request("GET"),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), 100)
            .await
            .unwrap();
        assert_eq!(bytes.as_ref(), b"download archive");
    }

    #[tokio::test]
    async fn chapter_manifest_rejects_job_path_traversal() {
        let root = TestRoot::new();
        let response = chapters(AxumPath(("../private".into(), 1)), State(root.state())).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn encoded_http_job_path_cannot_escape_outputs() {
        let root = TestRoot::new();
        let state = root.state();
        std::fs::create_dir_all(&state.config.paths.output_dir).unwrap();
        let outside = root.0.join("private");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("example.txt"), b"outside fixture").unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app(state.config)).await.unwrap();
        });
        let response = tokio::task::spawn_blocking(move || {
            use std::io::{Read, Write};
            let mut client = std::net::TcpStream::connect(address).unwrap();
            client.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
            client.write_all(b"GET /api/outputs/..%2Fprivate/example.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").unwrap();
            let mut bytes = Vec::new();
            client.read_to_end(&mut bytes).unwrap();
            String::from_utf8(bytes).unwrap()
        }).await.unwrap();
        server.abort();
        assert!(response.starts_with("HTTP/1.1 400"), "{response}");
        assert!(!response.contains("outside fixture"));
    }

    #[tokio::test]
    async fn normal_output_download_keeps_its_contents() {
        let root = TestRoot::new();
        let state = root.state();
        let job = state.config.paths.output_dir.join("valid-job");
        std::fs::create_dir_all(&job).unwrap();
        std::fs::write(job.join("chapter.mp3"), b"valid fixture").unwrap();
        let response = output(
            AxumPath(("valid-job".into(), "chapter.mp3".into())),
            State(state),
            request("GET"),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), 100)
            .await
            .unwrap();
        assert_eq!(bytes.as_ref(), b"valid fixture");
    }

    struct TestRoot(PathBuf);
    impl TestRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("converter-server-contract-{}", uuid()));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn state(&self) -> AppState {
            let config = AppConfig::from_paths(converter_core::paths::resolve_paths_from(
                HashMap::<String, String>::new(),
                self.0.clone(),
            ));
            AppState {
                config,
                jobs: Arc::new(RwLock::new(HashMap::new())),
            }
        }
    }
    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[tokio::test]
    async fn output_rejects_job_ids_that_escape_the_output_root() {
        let root = TestRoot::new();
        let state = root.state();
        std::fs::create_dir_all(&state.config.paths.output_dir).unwrap();
        let outside = root.0.join("private");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("example.txt"), b"outside fixture").unwrap();
        let response = output(
            AxumPath(("../private".into(), "example.txt".into())),
            State(state),
            request("GET"),
        )
        .await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }
}
