//! Compatibility HTTP contracts and durable snapshot state; not the embedded client runtime.
use converter_core::config::AppConfig;
use converter_core::model_store::ModelStoreError;
use converter_core::tts_preferences::TtsPreferences;
use serde::Deserialize;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::broadcast;
use tokio::sync::RwLock;

#[derive(Clone)]
pub(super) struct AppState {
    pub(super) config: AppConfig,
    pub(super) jobs: Arc<RwLock<HashMap<String, Job>>>,
    /// Serializes model installations within this process.
    pub(super) model_installs: Arc<tokio::sync::Mutex<()>>,
    pub(super) model_installer: ModelInstaller,
}

pub(super) type ModelInstall = Pin<Box<dyn Future<Output = Result<(), ModelStoreError>> + Send>>;
/// Installs one catalog voice into a model root. Production downloads and
/// verifies it; tests replace the network.
pub(super) type ModelInstaller = Arc<dyn Fn(PathBuf, &'static str) -> ModelInstall + Send + Sync>;
#[derive(Clone)]
pub(super) struct Job {
    pub(super) snapshot: JobSnapshot,
    pub(super) events: broadcast::Sender<SseMessage>,
    pub(super) cancellation: converter_core::piper::CancellationToken,
    pub(super) worker_active: bool,
}
#[derive(Clone, Debug)]
pub(super) enum SseMessage {
    Snapshot(JobSnapshot),
    Chapter(JobSnapshot),
}

/// HTTP lifecycle of a job, serialized as the strings existing clients and
/// persisted snapshots already use. `Interrupted` is HTTP-only: an active job
/// whose worker did not survive a server restart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum JobPhase {
    Queued,
    Running,
    Cancelling,
    Cancelled,
    /// Snapshots written by earlier servers may say `completed`.
    #[serde(alias = "completed")]
    Finished,
    Failed,
    Interrupted,
}

impl JobPhase {
    pub(super) fn is_active(self) -> bool {
        matches!(self, Self::Queued | Self::Running | Self::Cancelling)
    }

    pub(super) fn is_terminal(self) -> bool {
        !self.is_active()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobSnapshot {
    pub(super) job_id: String,
    pub(super) state: JobPhase,
    pub(super) events: Vec<String>,
    pub(super) raw_log: Vec<String>,
    pub(super) chapters_total: u32,
    pub(super) chapters_completed: u32,
    pub(super) progress_percent: f64,
    pub(super) chapter_progress: Vec<ChapterProgress>,
    pub(super) outputs: Vec<OutputAsset>,
    pub(super) error: Option<String>,
    pub(super) book_title: Option<String>,
    pub(super) book_author: Option<String>,
    pub(super) cover_url: Option<String>,
    pub(super) cover_mime_type: Option<String>,
    pub(super) log_url: Option<String>,
    pub(super) engine: Option<String>,
    pub(super) voice: Option<String>,
    pub(super) language: Option<String>,
    #[serde(default, alias = "tts_preferences")]
    pub(super) tts_preferences: Option<TtsPreferences>,
    pub(super) formatting_cues: bool,
    pub(super) ui_language: String,
    pub(super) no_parallel: bool,
}
/// Progress lines retained per job. Every SSE update carries the snapshot, so
/// an unbounded log would grow each message with the length of the book.
pub(super) const MAX_LOG_LINES: usize = 500;

fn push_bounded(lines: &mut Vec<String>, line: String) {
    if lines.len() >= MAX_LOG_LINES {
        lines.drain(..=lines.len() - MAX_LOG_LINES);
    }
    lines.push(line);
}

impl JobSnapshot {
    pub(super) fn push_event(&mut self, line: String) {
        push_bounded(&mut self.events, line);
    }

    pub(super) fn push_progress(&mut self, line: String) {
        push_bounded(&mut self.events, line.clone());
        push_bounded(&mut self.raw_log, line);
    }

    /// Retain the captured voices so a later resume repeats the same selection
    /// instead of the engine that happened to be active when the job stopped.
    pub(super) fn record_selection(&mut self, preferences: &TtsPreferences) {
        self.engine = Some(preferences.primary.engine.clone());
        self.voice = preferences.primary.voice.clone();
        self.tts_preferences = Some(preferences.clone());
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ChapterProgress {
    pub(super) index: u32,
    pub(super) name: String,
    pub(super) status: String,
    pub(super) engine: Option<String>,
    pub(super) download_url: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct OutputAsset {
    pub(super) name: String,
    pub(super) url: String,
    pub(super) size_bytes: u64,
}
#[derive(Debug, Serialize)]
pub(super) struct HealthResponse {
    pub(super) status: &'static str,
    pub(super) contract_version: &'static str,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ContractResponse {
    pub(super) version: &'static str,
    pub(super) backend: &'static str,
    pub(super) capabilities: Vec<&'static str>,
}
#[derive(Debug, Serialize)]
pub(super) struct MetadataResponse {
    pub(super) status: &'static str,
    pub(super) engine: String,
    pub(super) expected_wpm: u32,
    pub(super) persistent_root: String,
    pub(super) cache_dir: String,
    pub(super) output_dir: String,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct UploadResponse {
    pub(super) upload_id: String,
    pub(super) file_name: String,
    pub(super) book_title: Option<String>,
    pub(super) book_author: Option<String>,
    pub(super) cover_url: Option<String>,
    pub(super) cover_mime_type: Option<String>,
}
#[derive(Debug, Deserialize, Default)]
pub(super) struct LocalUpload {
    pub(super) path: String,
}
#[derive(Debug, Deserialize, Default)]
pub(super) struct CreateJob {
    #[serde(alias = "uploadId")]
    pub(super) upload_id: Option<String>,
    #[serde(alias = "ttsPreferences")]
    pub(super) tts_preferences: Option<TtsPreferences>,
    pub(super) engine: Option<String>,
    pub(super) voice: Option<String>,
    pub(super) language: Option<String>,
    pub(super) formatting_cues: Option<bool>,
    pub(super) ui_language: Option<String>,
    pub(super) no_parallel: Option<bool>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FulltextResponse {
    pub(super) job_id: String,
    pub(super) book_title: String,
    pub(super) book_author: String,
    pub(super) chapters: Vec<FulltextChapter>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FulltextChapter {
    pub(super) index: u32,
    pub(super) name: String,
    pub(super) source_path: String,
    pub(super) text: String,
    pub(super) char_count: usize,
}

pub(super) fn initial_job(id: String, f: &CreateJob) -> JobSnapshot {
    JobSnapshot {
        job_id: id,
        state: JobPhase::Queued,
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
        engine: f
            .tts_preferences
            .as_ref()
            .map(|preferences| preferences.primary.engine.clone())
            .or_else(|| f.engine.clone()),
        voice: f.tts_preferences.as_ref().map_or_else(
            || f.voice.clone(),
            |preferences| preferences.primary.voice.clone(),
        ),
        language: f.language.clone(),
        tts_preferences: f.tts_preferences.clone(),
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

/// The selection the shared worker captured for a job, from its durable
/// record. Snapshots written before typed preferences were stored keep only an
/// `engine` that progress events overwrite, so that field cannot be trusted.
pub(super) fn recorded_preferences(config: &AppConfig, job_id: &str) -> Option<TtsPreferences> {
    let record = converter_core::jobs::ConversionJobStore::new(&config.paths.jobs_dir)
        .ok()?
        .load(job_id)
        .ok()?;
    serde_json::from_value(record.metadata.get("tts_preferences")?.clone()).ok()
}

pub(super) fn snapshot_path(config: &AppConfig, job_id: &str) -> PathBuf {
    config
        .paths
        .jobs_dir
        .join(format!("{job_id}.snapshot.json"))
}

pub(super) fn persist_snapshot(config: &AppConfig, snapshot: &JobSnapshot) -> std::io::Result<()> {
    fs::create_dir_all(&config.paths.jobs_dir)?;
    let target = snapshot_path(config, &snapshot.job_id);
    let temporary = target.with_extension(format!("tmp-{}", std::process::id()));
    let bytes = serde_json::to_vec_pretty(snapshot)
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, target)
}

pub(super) fn load_snapshots(config: &AppConfig) -> HashMap<String, Job> {
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
        if snapshot.state.is_active() {
            snapshot.state = JobPhase::Interrupted;
            snapshot.error = Some("Server restarted before the conversion completed".into());
            snapshot.push_event("Conversion interrupted by server restart".into());
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
