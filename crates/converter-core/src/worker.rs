//! End-to-end conversion orchestration shared by the CLI and HTTP server.
use crate::{
    adaptive::AdaptiveThroughputController,
    audio::{self, ChapterMetadata},
    cache,
    config::AppConfig,
    conversion_control::ConversionControl,
    epub,
    jobs::{ConversionJobStore, JobError, JobRecord, JobState},
    piper::CancellationToken,
    platform_tts::PlatformTts,
    tts::{EdgeError, Telemetry},
};
use serde::{Deserialize, Serialize};
use std::{
    io,
    path::PathBuf,
    sync::{Arc, Mutex},
};
use thiserror::Error;

#[cfg(test)]
use crate::piper;
#[cfg(test)]
use std::{
    fs,
    path::Path,
    sync::atomic::{AtomicUsize, Ordering},
};

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub render_progress: Option<render_progress::RenderProgressSnapshot>,
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
    /// Identity of the exact source bytes used to produce these artifacts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_sha256: Option<String>,
    pub archive: String,
    pub cover: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tts_preferences: Option<crate::tts_preferences::TtsPreferences>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub used_selections: Vec<crate::tts_preferences::TtsSelection>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub synthesis_sessions: Vec<crate::tts_session::ResolvedIdentity>,
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
    #[error(transparent)]
    BookInput(crate::book_input::BookInputError),
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
    Piper(#[from] crate::piper::PiperError),
    #[error("invalid TTS selection: {0}")]
    InvalidSelection(String),
    #[error("conversion control error: {0}")]
    Control(#[from] crate::conversion_control::ConversionControlError),
    #[error("selected chapters have no readable text")]
    NoReadableText,
    #[error("text coverage mismatch: source={source_chars}, output={output_chars}")]
    TextCoverage {
        source_chars: usize,
        output_chars: usize,
    },
    #[error(transparent)]
    Synthesis(#[from] crate::tts_session::TtsFailure),
    #[error("system speech error: {0}")]
    PlatformTts(String),
    #[error("cancelled")]
    Cancelled,
    #[error("playback moved outside the current chapter window")]
    PlaybackWindowChanged,
    #[error("unsupported input: {0}")]
    Unsupported(String),
}
impl From<crate::book_input::BookInputError> for WorkerError {
    fn from(error: crate::book_input::BookInputError) -> Self {
        use crate::book_input::BookInputError;
        match error {
            BookInputError::Epub(source) => Self::Epub(source),
            BookInputError::Io(source) => Self::Io(source),
            BookInputError::Pdf(crate::ingestion::IngestionError::Cancelled) => Self::Cancelled,
            other => Self::BookInput(other),
        }
    }
}

pub type ProgressSink = Arc<dyn Fn(ProgressEvent) + Send + Sync>;
pub type ChapterCompletionSink = Arc<dyn Fn(ChapterCompletionEvent) + Send + Sync>;
pub type StreamingChunkSink = Arc<dyn Fn(usize, usize, &[u8]) -> bool + Send + Sync>;
pub type VersionedStreamingChunkSink =
    Arc<dyn Fn(usize, usize, &[u8], Option<u64>) -> bool + Send + Sync>;

/// Per-invocation controls; defaults retain cache reuse and serial selection.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ExecutionOptions {
    pub clear_cache: bool,
    pub force_reprocess: bool,
    pub max_performance: bool,
}

pub struct ConversionWorker {
    language_overrides: Vec<crate::language::LanguageOverride>,
    source_identity: Mutex<Option<String>>,
    /// Set while repairing a job's own output in place.
    repairing: std::sync::atomic::AtomicBool,
    expected_source_sha256: Mutex<Option<String>>,
    pronunciation: crate::pronunciation::PronunciationDictionary,
    render_progress: Mutex<render_progress::RenderProgress>,
    pub config: AppConfig,
    pub jobs: ConversionJobStore,
    pub cancel: CancellationToken,
    pub progress: Option<ProgressSink>,
    pub chapter_completed: Option<ChapterCompletionSink>,
    pub execution_options: ExecutionOptions,
    streaming_chunk: Option<VersionedStreamingChunkSink>,
    adaptive: Arc<AdaptiveThroughputController>,
    telemetry: Option<Telemetry>,
    control: Option<ConversionControl>,
    platform_tts: Option<Arc<dyn PlatformTts>>,
    platform_gate: Arc<Mutex<()>>,
    tts_sessions: Mutex<segment_synthesis::PreparedSessions>,
    tts_registry: crate::tts_session::TtsRegistry,
    tts_session_epoch: String,
    segment_policy: Mutex<crate::tts_preferences::SegmentPolicy>,
    initial_segment_policy: crate::tts_preferences::SegmentPolicy,
    fallback_chapters: Mutex<std::collections::HashSet<usize>>,
    #[cfg(test)]
    test_edge: Option<Arc<dyn Fn(&str) -> Result<Vec<u8>, WorkerError> + Send + Sync>>,
}
impl ConversionWorker {
    pub fn with_pronunciation(
        mut self,
        dictionary: crate::pronunciation::PronunciationDictionary,
    ) -> Result<Self, WorkerError> {
        dictionary.validate().map_err(WorkerError::Unsupported)?;
        self.pronunciation = dictionary;
        Ok(self)
    }

    pub fn new(config: AppConfig) -> Result<Self, WorkerError> {
        let jobs = ConversionJobStore::new(&config.paths.jobs_dir)?;
        Ok(Self {
            language_overrides: Vec::new(),
            source_identity: Mutex::new(None),
            repairing: Default::default(),
            expected_source_sha256: Mutex::new(None),
            pronunciation: Default::default(),
            render_progress: Default::default(),
            config,
            jobs,
            cancel: CancellationToken::default(),
            progress: None,
            chapter_completed: None,
            execution_options: ExecutionOptions::default(),
            streaming_chunk: None,
            adaptive: Arc::new(AdaptiveThroughputController::default()),
            telemetry: None,
            control: None,
            platform_tts: None,
            platform_gate: Arc::new(Mutex::new(())),
            tts_sessions: Default::default(),
            tts_registry: Default::default(),
            tts_session_epoch: crate::tts_session::new_session_id(),
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
    /// Composition roots register runtime adapters; orchestration stays unchanged.
    pub fn with_tts_registry(mut self, registry: crate::tts_session::TtsRegistry) -> Self {
        self.tts_registry = registry;
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
        self.streaming_chunk = Some(Arc::new(move |chapter, chunk, bytes, _| {
            sink(chapter, chunk, bytes)
        }));
        self
    }
    pub fn with_versioned_streaming_chunks(mut self, sink: VersionedStreamingChunkSink) -> Self {
        self.streaming_chunk = Some(sink);
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
    fn emit(&self, mut event: ProgressEvent) {
        // Synthesis call sites do not own the chapter counter.
        event.chapters_completed = event.chapters_completed.max(
            self.render_progress
                .lock()
                .expect("render progress lock")
                .completed_chapters(),
        );
        if event.state == "running"
            && self
                .control
                .as_ref()
                .is_none_or(|control| control.listening_plan().is_none())
        {
            event.render_progress = self
                .render_progress
                .lock()
                .expect("render progress lock")
                .snapshot();
            if let Some(progress) = &event.render_progress {
                // Final artifact publication, not the last generated byte, establishes completion.
                event.percent = (progress.fraction * 100.0).min(99.0);
            }
        }
        if let Some(sink) = &self.progress {
            sink(event)
        }
    }
}

mod chapter_audio_receipt;
use chapter_audio_receipt::discard_chapter_audio_receipt;
pub use chapter_audio_receipt::{prepare_retained_audio, retained_chapter_audio_is_intact};
mod chapter_audio_recovery;
mod chapter_execution;
mod chapter_range_selection;
pub use chapter_range_selection::{chapter_range_positions, ChapterRangeError};
mod conversion_input_policy;
use conversion_input_policy::chapter_selection_matches;
pub(crate) use conversion_input_policy::persisted_request_path;
mod conversion_schedule;
mod edge_synthesis_execution;
pub use edge_synthesis_execution::{edge_audition_voice, synthesize_edge_audition};
mod error_code;
pub(crate) use error_code::book_input_code;
pub use error_code::{ERROR_CODE_CLOSE, ERROR_CODE_OPEN};
pub mod background_pacing;
mod heading_pauses;
mod interrupted_jobs;
mod job_lifecycle;
mod language_routing;
mod native_tts_adapters;
mod playback_chunk_delivery;
pub mod render_progress;
mod request_preferences;
mod segment_audio_cache;
mod segment_synthesis;
mod selection_model_paths;
mod tts_cache_identity;
mod typed_speech_policy;

use chapter_audio_receipt::*;
use chapter_audio_recovery::*;
use conversion_input_policy::*;
use edge_synthesis_execution::*;

#[cfg(test)]
#[path = "worker/worker_contract_tests.rs"]
mod tests;
