//! Job status/SSE, cancellation and resumption at the compatibility boundary.
use super::http_conversion_routes::{start_worker, Launch};
use super::http_input_paths::safe_leaf;
use super::http_runtime_state::{
    persist_snapshot, recorded_preferences, AppState, JobPhase, JobSnapshot, SseMessage,
};
use super::http_speech_selection::SpeechSelection;
use axum::extract::Path as AxumPath;
use axum::extract::State;
use axum::http::header;
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::sse::Event;
use axum::response::sse::KeepAlive;
use axum::response::sse::Sse;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use converter_core::worker::ConversionWorker;
use futures_util::stream::{self, StreamExt};
use std::convert::Infallible;
use std::time::Duration;
use tokio::sync::broadcast;

pub(super) async fn status(
    AxumPath(id): AxumPath<String>,
    State(state): State<AppState>,
) -> Response {
    match state.jobs.read().await.get(&id) {
        Some(job) => (StatusCode::OK, Json(job.snapshot.clone())).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
pub(super) async fn stream_job(
    AxumPath(id): AxumPath<String>,
    State(state): State<AppState>,
) -> Response {
    let (initial, receiver) = match state.jobs.read().await.get(&id) {
        Some(job) => (job.snapshot.clone(), job.events.subscribe()),
        None => return StatusCode::NOT_FOUND.into_response(),
    };
    let initially_terminal = initial.state.is_terminal();
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
                    let terminal = snapshot.state.is_terminal();
                    Some((Ok(snapshot_event(&snapshot, false)), (receiver, terminal)))
                }
                Ok(SseMessage::Chapter(snapshot)) => {
                    let terminal = snapshot.state.is_terminal();
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
pub(super) async fn cancel(
    AxumPath(id): AxumPath<String>,
    State(state): State<AppState>,
) -> Response {
    match state.jobs.write().await.get_mut(&id) {
        Some(job) if job.snapshot.state.is_terminal() => (
            StatusCode::OK,
            Json(serde_json::json!({"status": job.snapshot.state})),
        )
            .into_response(),
        Some(job) => {
            let mut snapshot = job.snapshot.clone();
            snapshot.state = if snapshot.state == JobPhase::Queued {
                JobPhase::Cancelled
            } else {
                JobPhase::Cancelling
            };
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
pub(super) async fn resume_job(
    AxumPath(id): AxumPath<String>,
    State(state): State<AppState>,
) -> Response {
    if !safe_leaf(&id) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let mut jobs = state.jobs.write().await;
    let Some(job) = jobs.get_mut(&id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if matches!(
        job.snapshot.state,
        JobPhase::Queued | JobPhase::Running | JobPhase::Finished
    ) {
        return (
            StatusCode::OK,
            Json(serde_json::json!({"status": job.snapshot.state})),
        )
            .into_response();
    }
    if job.worker_active || job.snapshot.state == JobPhase::Cancelling {
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
    // Only a job that will actually restart needs a usable voice selection.
    let recorded = match job.snapshot.tts_preferences {
        Some(_) => None,
        None => recorded_preferences(&state.config, &id),
    };
    let plan = match (SpeechSelection {
        preferences: job.snapshot.tts_preferences.as_ref().or(recorded.as_ref()),
        engine: job.snapshot.engine.as_deref(),
        voice: job.snapshot.voice.as_deref(),
        language: job.snapshot.language.as_deref(),
    })
    .plan(&state.config)
    {
        Ok(plan) => plan,
        Err(error) => return error.into_response(),
    };
    let worker = match ConversionWorker::new(state.config.clone()) {
        Ok(worker) => worker,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let mut snapshot = job.snapshot.clone();
    snapshot.state = JobPhase::Queued;
    snapshot.error = None;
    snapshot.record_selection(&plan.preferences);
    if persist_snapshot(&state.config, &snapshot).is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let launch = Launch {
        plan,
        input,
        job_id: id,
        language: snapshot.language.clone(),
        no_parallel: snapshot.no_parallel,
        resuming: true,
    };
    job.snapshot = snapshot;
    job.cancellation = Default::default();
    job.worker_active = true;
    let sender = job.events.clone();
    let cancellation = job.cancellation.clone();
    let _ = sender.send(SseMessage::Snapshot(job.snapshot.clone()));
    drop(jobs);
    start_worker(state, worker, launch, sender, cancellation);
    (
        StatusCode::OK,
        Json(serde_json::json!({"status": JobPhase::Queued})),
    )
        .into_response()
}
pub(super) async fn log(AxumPath(id): AxumPath<String>, State(state): State<AppState>) -> Response {
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
pub(super) async fn resumable_jobs(State(state): State<AppState>) -> Response {
    let jobs = state
        .jobs
        .read()
        .await
        .values()
        .filter(|job| job.snapshot.state.is_active() || job.snapshot.state == JobPhase::Interrupted)
        .map(|job| job.snapshot.clone())
        .collect::<Vec<_>>();
    let count = jobs.len();
    (
        StatusCode::OK,
        Json(serde_json::json!({"resumableJobs":jobs,"count":count})),
    )
        .into_response()
}
pub(super) async fn recent_jobs(State(state): State<AppState>) -> Response {
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
pub(super) fn snapshot_event(snapshot: &JobSnapshot, chapter: bool) -> Event {
    let event = Event::default().data(serde_json::to_string(snapshot).unwrap_or_default());
    if chapter {
        event.event("chapter_update")
    } else {
        event
    }
}
