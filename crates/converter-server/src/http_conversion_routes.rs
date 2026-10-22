//! Validate HTTP conversion preferences and start the shared Rust worker.
use super::http_input_paths::{safe_leaf, uploaded_file, uuid};
use super::http_runtime_state::{
    initial_job, persist_snapshot, AppState, ChapterProgress, CreateJob, Job, JobSnapshot,
    OutputAsset, SseMessage,
};
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use converter_core::tts_preferences::TtsPreferences;
use converter_core::worker::ConversionRequest;
use converter_core::worker::ConversionWorker;
use converter_core::worker::OutputManifest;
use converter_core::worker::ProgressEvent;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::broadcast;

// This compatibility server has no embedded local-provider adapter. Reject an
// unavailable typed selection before creating work rather than falling back to Edge.
pub(super) fn validate_server_preferences(
    preferences: Option<&TtsPreferences>,
    language: Option<&str>,
) -> Result<(), (StatusCode, String)> {
    let Some(preferences) = preferences else {
        return Ok(());
    };
    preferences
        .validate(language)
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    if std::iter::once(&preferences.primary)
        .chain(preferences.secondary.iter())
        .any(|selection| selection.engine != "edge")
    {
        return Err((StatusCode::UNPROCESSABLE_ENTITY,
            "This compatibility server does not embed Piper or platform speech. Use the native CLI/apps or browser WASM for local voices, or explicitly select Edge.".into()));
    }
    Ok(())
}
pub(super) fn preferences_error(error: (StatusCode, String)) -> Response {
    (error.0, Json(serde_json::json!({"detail":error.1}))).into_response()
}

pub(super) async fn create_job(
    State(state): State<AppState>,
    Json(form): Json<CreateJob>,
) -> Response {
    if let Err(error) =
        validate_server_preferences(form.tts_preferences.as_ref(), form.language.as_deref())
    {
        return preferences_error(error);
    }
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
        piper_model: None,
        piper_config: None,
        tts_preferences: form.tts_preferences.clone(),
        models_root: Some(state.config.paths.models_dir.join("tts")),
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

pub(super) fn start_worker(
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

pub(super) fn apply_manifest(
    snapshot: &mut JobSnapshot,
    manifest: &OutputManifest,
    output_dir: &Path,
) {
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
