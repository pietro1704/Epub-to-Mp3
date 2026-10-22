//! End-to-end conversion orchestration shared by the CLI and HTTP server.
use crate::{
    adaptive::AdaptiveThroughputController,
    audio::{self, ChapterMetadata},
    cache,
    config::AppConfig,
    conversion_control::ConversionControl,
    epub,
    jobs::{ConversionJobStore, JobError, JobRecord, JobState},
    piper::{self, CancellationToken},
    platform_tts::PlatformTts,
    tts::{EdgeError, Telemetry},
};
use serde::{Deserialize, Serialize};
use std::{
    io,
    path::PathBuf,
    sync::{atomic::AtomicUsize, Arc, Mutex},
};
use thiserror::Error;

#[cfg(test)]
use crate::platform_tts;
#[cfg(test)]
use std::{fs, path::Path, sync::atomic::Ordering};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ConversionRequest {
    pub input: PathBuf,
    pub job_id: String,
    #[serde(default)]
    pub tts_preferences: Option<crate::tts_preferences::TtsPreferences>,
    #[serde(default)]
    pub models_root: Option<PathBuf>,
    pub engine: Option<String>,
    pub voice: Option<String>,
    pub language: Option<String>,
    #[serde(default)]
    pub piper_model: Option<PathBuf>,
    #[serde(default)]
    pub piper_config: Option<PathBuf>,
    pub chapter_indices: Option<Vec<String>>,
    pub no_parallel: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProgressEvent {
    pub job_id: String,
    pub state: String,
    pub chapter_index: Option<usize>,
    pub chapters_total: usize,
    pub chapters_completed: usize,
    pub percent: f64,
    pub engine: Option<String>,
    #[serde(default)]
    pub model_id: Option<String>,
    #[serde(default)]
    pub voice: Option<String>,
    #[serde(default)]
    pub fallback_used: bool,
    pub message: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ChapterCompletionEvent {
    pub job_id: String,
    pub book_title: String,
    pub book_author: String,
    pub chapter_index: usize,
    pub chapters_total: usize,
    pub chapters_completed: usize,
    pub chapter_title: String,
    pub filename: String,
    pub audio_path: PathBuf,
    pub text_chars: usize,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct OutputManifest {
    pub job_id: String,
    pub title: String,
    pub author: String,
    pub chapters: Vec<ChapterMetadata>,
    /// Full parsed source count; selected chapters remain represented by `chapters`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_chapters_total: Option<usize>,
    pub archive: String,
    pub cover: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tts_preferences: Option<crate::tts_preferences::TtsPreferences>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub used_selections: Vec<crate::tts_preferences::TtsSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tts_policy_state: Option<crate::tts_preferences::SegmentPolicy>,
    #[serde(default, skip_serializing_if = "no_fallback")]
    pub fallback_used: bool,
}

fn no_fallback(value: &bool) -> bool {
    !*value
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("job error: {0}")]
    Job(#[from] JobError),
    #[error("EPUB error: {0}")]
    Epub(#[from] epub::EpubError),
    #[error("cache error: {0}")]
    Cache(#[from] cache::CacheError),
    #[error("audio error: {0}")]
    Audio(#[from] audio::AudioError),
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("Edge error: {0}")]
    Edge(#[from] EdgeError),
    #[error("Piper error: {0}")]
    Piper(String),
    #[error("system speech error: {0}")]
    PlatformTts(String),
    #[error("cancelled")]
    Cancelled,
    #[error("playback moved outside the current chapter window")]
    PlaybackWindowChanged,
    #[error("unsupported input: {0}")]
    Unsupported(String),
}
pub type ProgressSink = Arc<dyn Fn(ProgressEvent) + Send + Sync>;
pub type ChapterCompletionSink = Arc<dyn Fn(ChapterCompletionEvent) + Send + Sync>;
pub type StreamingChunkSink = Arc<dyn Fn(usize, usize, &[u8]) -> bool + Send + Sync>;

/// Per-invocation controls; defaults retain cache reuse and serial selection.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ExecutionOptions {
    pub clear_cache: bool,
    pub force_reprocess: bool,
    pub max_performance: bool,
}

impl ExecutionOptions {
    fn chapter_parallelism(
        self,
        no_parallel: bool,
        configured: usize,
        maximum: usize,
        cap: usize,
    ) -> usize {
        if no_parallel && !self.max_performance {
            1
        } else {
            configured.min(maximum).min(cap).max(1)
        }
    }
}

pub struct ConversionWorker {
    pub config: AppConfig,
    pub jobs: ConversionJobStore,
    pub cancel: CancellationToken,
    pub progress: Option<ProgressSink>,
    pub chapter_completed: Option<ChapterCompletionSink>,
    pub execution_options: ExecutionOptions,
    pub piper_model: Option<Arc<piper::PreparedPiperModel>>,
    streaming_chunk: Option<StreamingChunkSink>,
    adaptive: Arc<AdaptiveThroughputController>,
    telemetry: Option<Telemetry>,
    control: Option<ConversionControl>,
    platform_tts: Option<Arc<dyn PlatformTts>>,
    platform_gate: Mutex<()>,
    consecutive_edge_failures: AtomicUsize,
    segment_policy: Mutex<crate::tts_preferences::SegmentPolicy>,
    initial_segment_policy: crate::tts_preferences::SegmentPolicy,
    fallback_chapters: Mutex<std::collections::HashSet<usize>>,
    #[cfg(test)]
    test_edge: Option<Arc<dyn Fn(&str) -> Result<Vec<u8>, WorkerError> + Send + Sync>>,
}
impl ConversionWorker {
    pub fn new(config: AppConfig) -> Result<Self, WorkerError> {
        let jobs = ConversionJobStore::new(&config.paths.jobs_dir)?;
        Ok(Self {
            config,
            jobs,
            cancel: CancellationToken::default(),
            progress: None,
            chapter_completed: None,
            execution_options: ExecutionOptions::default(),
            piper_model: None,
            streaming_chunk: None,
            adaptive: Arc::new(AdaptiveThroughputController::default()),
            telemetry: None,
            control: None,
            platform_tts: None,
            platform_gate: Mutex::new(()),
            consecutive_edge_failures: AtomicUsize::new(0),
            segment_policy: Mutex::new(crate::tts_preferences::SegmentPolicy::default()),
            initial_segment_policy: crate::tts_preferences::SegmentPolicy::default(),
            fallback_chapters: Default::default(),
            #[cfg(test)]
            test_edge: None,
        })
    }
    pub fn with_execution_options(mut self, options: ExecutionOptions) -> Self {
        self.execution_options = options;
        self
    }
    pub fn with_piper_model(mut self, model: Option<Arc<piper::PreparedPiperModel>>) -> Self {
        self.piper_model = model;
        self
    }
    /// Carry the Rust-owned failure policy across incremental chapter requests.
    pub fn with_tts_policy_state(mut self, state: crate::tts_preferences::SegmentPolicy) -> Self {
        self.initial_segment_policy = state.clone();
        *self.segment_policy.lock().expect("segment policy lock") = state;
        self
    }
    pub fn with_platform_tts(mut self, provider: Arc<dyn PlatformTts>) -> Self {
        self.platform_tts = Some(provider);
        self
    }
    pub fn with_progress(mut self, sink: ProgressSink) -> Self {
        self.progress = Some(sink);
        self
    }
    pub fn with_chapter_completed(mut self, sink: ChapterCompletionSink) -> Self {
        self.chapter_completed = Some(sink);
        self
    }
    pub fn with_streaming_chunks(mut self, sink: StreamingChunkSink) -> Self {
        self.streaming_chunk = Some(sink);
        self
    }
    pub fn with_adaptive_throughput(
        mut self,
        controller: Arc<AdaptiveThroughputController>,
    ) -> Self {
        self.adaptive = controller;
        self
    }
    pub fn with_tts_telemetry(mut self, telemetry: Telemetry) -> Self {
        self.telemetry = Some(telemetry);
        self
    }
    pub fn with_control(mut self, control: ConversionControl) -> Self {
        self.cancel = control.cancellation_token();
        self.control = Some(control);
        self
    }
    pub fn with_cancellation(mut self, cancel: CancellationToken) -> Self {
        self.cancel = cancel;
        self
    }
    pub fn cancel(&self) {
        self.cancel.cancel();
    }
    pub fn run(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        let primary = request
            .tts_preferences
            .as_ref()
            .map(|preferences| &preferences.primary);
        let metadata = serde_json::json!({
            "input": request.input,
            "engine": primary.map(|selection| &selection.engine).or(request.engine.as_ref()),
            "voice": primary.map_or(request.voice.as_ref(), |selection| selection.voice.as_ref()),
            "language": request.language,
            "tts_preferences": request.tts_preferences,
            "models_root": request.models_root,
            "piper_model": request.piper_model,
            "piper_config": request.piper_config
        });

        self.jobs.create(JobRecord::new(
            &request.job_id,
            metadata.as_object().cloned().unwrap_or_default(),
        ))?;
        self.run_prepared(request)
    }

    /// Retry a job whose previous worker has stopped, preserving its output ID
    /// and chapter paths across attempts.
    pub fn resume(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        match self.jobs.restart(&request.job_id) {
            Ok(_) => self.run_prepared(request),
            Err(JobError::NotFound(_)) => self.run(request),
            Err(error) => Err(error.into()),
        }
    }

    fn run_prepared(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        self.jobs.transition(&request.job_id, JobState::Running)?;
        let result = self.run_inner(&request);
        match &result {
            Ok(_) => {
                self.jobs.transition(&request.job_id, JobState::Completed)?;
            }
            Err(WorkerError::Cancelled) => {
                // A control token can cancel without a persisted request. Follow
                // the state machine before reporting terminal cancellation.
                if self.jobs.load(&request.job_id)?.state != JobState::Cancelling {
                    self.jobs.request_cancellation(&request.job_id)?;
                }
                self.jobs.transition(&request.job_id, JobState::Cancelled)?;
            }
            Err(_) => {
                let _ = self.jobs.transition(&request.job_id, JobState::Failed);
            }
        }
        result
    }
    #[allow(dead_code)]
    fn emit(&self, event: ProgressEvent) {
        if let Some(sink) = &self.progress {
            sink(event)
        }
    }
}

mod chapter_audio_receipt;
mod chapter_audio_recovery;
mod chapter_execution;
mod conversion_input_policy;
mod conversion_schedule;
mod edge_synthesis_execution;
mod platform_speech_policy;
mod playback_chunk_delivery;
mod provider_execution;
mod typed_speech_policy;

use chapter_audio_receipt::*;
use chapter_audio_recovery::*;
use conversion_input_policy::*;
use edge_synthesis_execution::*;
use playback_chunk_delivery::*;

#[cfg(test)]
#[path = "worker/worker_contract_tests.rs"]
mod tests;
