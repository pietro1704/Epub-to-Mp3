//! Compatibility HTTP contracts and durable snapshot state; not the embedded client runtime.
use converter_core::config::AppConfig;
use converter_core::tts_preferences::TtsPreferences;
use serde::Deserialize;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::broadcast;
use tokio::sync::RwLock;

#[derive(Clone)]
pub(super) struct AppState {
    pub(super) config: AppConfig,
    pub(super) jobs: Arc<RwLock<HashMap<String, Job>>>,
}
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobSnapshot {
    pub(super) job_id: String,
    pub(super) state: String,
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
