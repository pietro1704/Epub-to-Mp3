//! Start the shared Rust worker for an HTTP conversion and mirror its progress.
use super::http_input_paths::{safe_leaf, uploaded_file, uuid};
use super::http_model_routes::install_serialized;
use super::http_runtime_state::{
    initial_job, persist_snapshot, AppState, ChapterProgress, CreateJob, Job, JobPhase,
    JobSnapshot, OutputAsset, SseMessage,
};
use super::http_speech_selection::{conversion_request, SelectionPlan, SpeechSelection};
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use converter_core::worker::ConversionRequest;
use converter_core::worker::ConversionWorker;
use converter_core::worker::OutputManifest;
use converter_core::worker::ProgressEvent;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::broadcast;
use tokio::sync::RwLock;

fn server_error(detail: String) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(serde_json::json!({ "detail": detail })),
    )
        .into_response()
}

pub(super) async fn create_job(
    State(state): State<AppState>,
    Json(form): Json<CreateJob>,
) -> Response {
    let plan = match (SpeechSelection {
        preferences: form.tts_preferences.as_ref(),
        engine: form.engine.as_deref(),
        voice: form.voice.as_deref(),
        language: form.language.as_deref(),
    })
    .plan(&state.config)
    {
        Ok(plan) => plan,
        Err(error) => return error.into_response(),
    };
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
    let mut snapshot = initial_job(id.clone(), &form);
    snapshot.record_selection(&plan.preferences);
    // Publish the job only once its worker exists and its state is durable;
    // otherwise a queued job would remain visible with nothing to run it.
    let prepared = ConversionWorker::new(state.config.clone())
        .map_err(|error| format!("Could not prepare the conversion: {error}"))
        .and_then(|worker| {
            persist_snapshot(&state.config, &snapshot)
                .map_err(|error| format!("Could not persist the conversion: {error}"))?;
            Ok(worker)
        });
    let worker = match prepared {
        Ok(worker) => worker,
        Err(detail) => {
            // Nothing will ever run or resume this job; do not keep its input.
            let _ = tokio::fs::remove_dir_all(&job_input_dir).await;
            return server_error(detail);
        }
    };
    let (sender, _) = broadcast::channel(64);
    let cancellation = converter_core::piper::CancellationToken::default();
    state.jobs.write().await.insert(
        id.clone(),
        Job {
            snapshot,
            events: sender.clone(),
            cancellation: cancellation.clone(),
            worker_active: true,
        },
    );
    let launch = Launch {
        plan,
        input: input_copy,
        job_id: id.clone(),
        language: form.language.clone(),
        no_parallel: form.no_parallel.unwrap_or(false),
        resuming: false,
    };
    start_worker(state, worker, launch, sender, cancellation);
    (StatusCode::OK, Json(serde_json::json!({ "jobId": id }))).into_response()
}

/// Mirror one worker progress event into the job snapshot and its SSE stream.
pub(super) fn record_progress(
    jobs: &RwLock<HashMap<String, Job>>,
    sender: &broadcast::Sender<SseMessage>,
    event: ProgressEvent,
) {
    // The worker reports from its blocking thread. An uncontended lock avoids
    // parking it; a contended one may block there without stalling the runtime.
    let mut guard = match jobs.try_write() {
        Ok(guard) => guard,
        Err(_) => jobs.blocking_write(),
    };
    let Some(job) = guard.get_mut(&event.job_id) else {
        return;
    };
    // Segments already synthesizing still report after a cancellation request.
    if job.snapshot.state != JobPhase::Cancelling {
        job.snapshot.state = JobPhase::Running;
    }
    job.snapshot.chapters_total = event.chapters_total as u32;
    job.snapshot.chapters_completed = event.chapters_completed as u32;
    job.snapshot.progress_percent = event.percent;
    job.snapshot.engine = event.engine;
    job.snapshot.push_progress(event.message);
    let _ = sender.send(SseMessage::Chapter(job.snapshot.clone()));
}

/// Everything a queued job needs once its voices are available.
pub(super) struct Launch {
    pub(super) plan: SelectionPlan,
    pub(super) input: PathBuf,
    pub(super) job_id: String,
    pub(super) language: Option<String>,
    pub(super) no_parallel: bool,
    pub(super) resuming: bool,
}

/// Install the voices the selection still lacks, then resolve it into the
/// worker request. The job stays queued and reports each installation.
async fn prepare_request(
    state: &AppState,
    launch: Launch,
    sender: &broadcast::Sender<SseMessage>,
) -> Result<ConversionRequest, String> {
    for model_id in &launch.plan.missing_models {
        if let Some(job) = state.jobs.write().await.get_mut(&launch.job_id) {
            job.snapshot
                .push_event(format!("Installing voice model {model_id}"));
            let _ = sender.send(SseMessage::Snapshot(job.snapshot.clone()));
        }
        install_serialized(state, model_id)
            .await
            .map_err(|error| format!("Could not install voice model {model_id}: {error}"))?;
    }
    let selection = launch.plan.resolve(&state.config)?;
    Ok(conversion_request(
        selection,
        launch.input,
        launch.job_id,
        launch.language,
        launch.no_parallel,
    ))
}

pub(super) fn start_worker(
    state: AppState,
    worker: ConversionWorker,
    launch: Launch,
    sender: broadcast::Sender<SseMessage>,
    cancellation: converter_core::piper::CancellationToken,
) {
    let id = launch.job_id.clone();
    let resuming = launch.resuming;
    tokio::spawn(async move {
        let prepared = prepare_request(&state, launch, &sender).await;
        let jobs = state.jobs.clone();
        // A join failure means the blocking task panicked; its job state is
        // then whatever the worker last recorded.
        let _ = tokio::task::spawn_blocking(move || {
            let outcome = prepared
                .map_err(|detail| (JobPhase::Failed, detail))
                .and_then(|request| {
                    let progress_jobs = jobs.clone();
                    let progress_sender = sender.clone();
                    let worker = worker
                        .with_progress(Arc::new(move |event: ProgressEvent| {
                            record_progress(&progress_jobs, &progress_sender, event)
                        }))
                        // A job cancelled while its voice was installing stops here.
                        .with_cancellation(cancellation);
                    let result = if resuming {
                        worker.resume(request)
                    } else {
                        worker.run(request)
                    };
                    result.map_err(|error| {
                        let phase =
                            if matches!(error, converter_core::worker::WorkerError::Cancelled) {
                                JobPhase::Cancelled
                            } else {
                                JobPhase::Failed
                            };
                        (phase, error.to_string())
                    })
                });
            let mut guard = jobs.blocking_write();
            let Some(job) = guard.get_mut(&id) else {
                return;
            };
            job.worker_active = false;
            match outcome {
                Ok(manifest) => {
                    apply_manifest(&mut job.snapshot, &manifest, &state.config.paths.output_dir)
                }
                Err((phase, detail)) => {
                    job.snapshot.state = phase;
                    job.snapshot.error = Some(detail.clone());
                    job.snapshot.push_event(detail);
                }
            }
            // The worker has already stopped, so a storage failure cannot be
            // returned to a caller. Keep it visible to clients and the log route.
            if let Err(error) = persist_snapshot(&state.config, &job.snapshot) {
                job.snapshot
                    .push_event(format!("Could not persist the final job state: {error}"));
            }
            let _ = sender.send(SseMessage::Snapshot(job.snapshot.clone()));
        })
        .await;
    });
}

pub(super) fn apply_manifest(
    snapshot: &mut JobSnapshot,
    manifest: &OutputManifest,
    output_dir: &Path,
) {
    snapshot.state = JobPhase::Finished;
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
    snapshot.push_event("Conversion finished".into());
}
