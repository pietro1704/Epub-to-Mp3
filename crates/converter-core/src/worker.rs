//! End-to-end conversion orchestration shared by the CLI and HTTP server.
use crate::{
    adaptive::AdaptiveThroughputController,
    audio::{self, ChapterMetadata},
    cache,
    config::AppConfig,
    conversion_control::ConversionControl,
    epub,
    jobs::{JobError, JobManager, JobRecord, JobState},
    piper::{self, CancellationToken, PiperConfig},
    platform_tts::{self, PlatformTts},
    tts::{EdgeError, Telemetry},
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
};
use thiserror::Error;

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
    #[serde(default, skip_serializing_if = "is_default_manifest_field")]
    pub tts_policy_state: crate::tts_preferences::SegmentPolicy,
    #[serde(default, skip_serializing_if = "is_default_manifest_field")]
    pub fallback_used: bool,
}
fn is_default_manifest_field<T: Default + PartialEq>(value: &T) -> bool {
    value == &T::default()
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
    pub jobs: JobManager,
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
        let jobs = JobManager::new(&config.paths.jobs_dir)?;
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
    fn run_inner(&self, request: &ConversionRequest) -> Result<OutputManifest, WorkerError> {
        if request
            .engine
            .as_deref()
            .is_some_and(|e| !matches!(e, "auto" | "piper" | "edge" | "system"))
        {
            return Err(WorkerError::Piper("Unsupported conversion engine".into()));
        }
        self.consecutive_edge_failures.store(0, Ordering::Release);
        self.fallback_chapters
            .lock()
            .expect("fallback chapter lock")
            .clear();
        *self.segment_policy.lock().expect("segment policy lock") =
            self.initial_segment_policy.clone();
        if !request.input.is_file() {
            return Err(WorkerError::Io(io::Error::new(
                io::ErrorKind::NotFound,
                request.input.display().to_string(),
            )));
        }
        let ext = request
            .input
            .extension()
            .and_then(|x| x.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if ext != "epub" {
            return Err(WorkerError::Unsupported(ext));
        }
        // Read the immutable source once: parsing the ZIP and hashing it from
        // separate file handles doubled disk I/O for every conversion.
        let source = fs::read(&request.input)?;
        let book_key = cache::sha256_bytes(&source);
        let book = epub::parse_epub(std::io::Cursor::new(&source))?;
        let source_chapters_total = book.chapters.len();
        let cache_dir = self.config.paths.cache_dir.join(&book_key);
        let output_dir = self.config.paths.output_dir.join(&request.job_id);
        fs::create_dir_all(&cache_dir)?;
        fs::create_dir_all(&output_dir)?;
        cache::atomic_write_json(
            self.config
                .paths
                .jobs_dir
                .join("requests")
                .join(format!("{}.json", request.job_id)),
            request,
        )?;
        let chapters: Vec<_> = book
            .chapters
            .iter()
            .enumerate()
            .filter(|(position, chapter)| {
                request
                    .chapter_indices
                    .as_ref()
                    .map(|wanted| {
                        wanted.iter().any(|value| {
                            chapter_selection_matches(value, &chapter.index, *position)
                        })
                    })
                    .unwrap_or(true)
            })
            .map(|(source_index, chapter)| (source_index, chapter))
            .collect();
        let total = chapters.len();
        let source_text_chars: usize = chapters
            .iter()
            .map(|(_, chapter)| chapter.text.chars().count())
            .sum();
        if total == 0 || source_text_chars == 0 {
            return Err(WorkerError::Piper(
                "selected chapters have no readable text".into(),
            ));
        }
        if let Some(control) = &self.control {
            control
                .attach(&chapters.iter().map(|(index, _)| *index).collect::<Vec<_>>())
                .map_err(|error| WorkerError::Piper(error.to_string()))?;
        }
        let detected_language = request
            .language
            .as_deref()
            .or(book.language.as_deref())
            .or_else(|| {
                book.chapters
                    .first()
                    .and_then(|chapter| detect_language(&chapter.text))
            });
        let parallelism = if (request.no_parallel && !self.execution_options.max_performance)
            || request.tts_preferences.is_some()
        {
            1
        } else {
            let configured = std::env::var("RUST_CHAPTER_PARALLELISM")
                .ok()
                .and_then(|value| value.parse().ok())
                .filter(|value| *value > 0)
                .unwrap_or_else(|| {
                    std::thread::available_parallelism()
                        .map(|v| v.get())
                        .unwrap_or(1)
                });
            let cap = std::env::var("RUST_CHAPTER_PARALLELISM_CAP")
                .ok()
                .and_then(|value| value.parse().ok())
                .filter(|value| *value > 0)
                .unwrap_or(8);
            self.execution_options.chapter_parallelism(
                request.no_parallel,
                configured,
                self.config.max_parallel,
                cap,
            )
        };
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(parallelism)
            .build()
            .map_err(|error| WorkerError::Piper(error.to_string()))?;
        let results = Mutex::new(Vec::with_capacity(total));
        let completed = AtomicUsize::new(0);
        let system_notice_emitted = std::sync::atomic::AtomicBool::new(false);
        let process_chapter = |position: usize,
                               source_index: usize,
                               chapter: &epub::Chapter|
         -> Result<(), WorkerError> {
            if self.cancel.is_cancelled() || self.jobs.is_cancellation_requested(&request.job_id)? {
                return Err(WorkerError::Cancelled);
            }
            let text_path = cache_dir.join(format!("{}.json", chapter.index.replace('.', "_")));
            let text = if self.execution_options.clear_cache {
                cache::refresh_chapter_text(
                    &self.config.paths.cache_dir,
                    &book_key,
                    &format!("{}.json", chapter.index.replace('.', "_")),
                    &chapter.text,
                )?
            } else {
                cached_chapter_text(&text_path, &chapter.text)?
            };
            let stem = format!("{:04}-{}", position + 1, sanitize(&chapter.name));
            let mp3 = output_dir.join(format!("{stem}.mp3"));
            let language = detected_language;
            let engine = request
                .tts_preferences
                .as_ref()
                .map(|p| p.primary.engine.clone())
                .unwrap_or_else(|| select_engine(request.engine.as_deref(), &self.config));
            let language = request.language.as_deref().or(language);
            let prepared_identity = self
                .piper_model
                .as_ref()
                .map(|model| model.cache_identity());
            let base_request_key = chapter_audio_request_key(
                &book_key,
                &chapter.index,
                &text,
                if let Some(identity) = prepared_identity.as_deref().filter(|_| engine == "piper") {
                    identity
                } else if self.platform_tts.is_some() && engine == "edge" {
                    "edge+system-v2"
                } else {
                    &engine
                },
                request.voice.as_deref(),
                language,
            )?;
            let request_key = if let Some(preferences) = &request.tts_preferences {
                preferences.validate(language).map_err(WorkerError::Piper)?;
                let mut identities = Vec::new();
                for selection in
                    std::iter::once(&preferences.primary).chain(preferences.secondary.iter())
                {
                    if selection.engine == "piper" {
                        let (model, config) = self.selection_model_paths(request, selection);
                        if !model.is_file() || !config.is_file() {
                            let id = selection
                                .model_id
                                .as_deref()
                                .unwrap_or(crate::tts_preferences::FABER_MODEL_ID);
                            return Err(WorkerError::Piper(format!("Piper model {id} is not installed. Install it in Models or run models install {id}.")));
                        }
                        identities.push(cache::sha256_file(model)?);

                        identities.push(cache::sha256_file(config)?);
                    }
                }
                cache::sha256_bytes(
                    format!(
                        "{base_request_key}{}",
                        preferences.cache_fingerprint(language, &identities)
                    )
                    .as_bytes(),
                )
            } else {
                base_request_key
            };
            let cached = !self.execution_options.force_reprocess
                && chapter_audio_is_complete(&mp3, &request_key);

            if cached {
                if let Ok(receipt) =
                    cache::read_json::<ChapterAudioReceipt>(chapter_audio_receipt_path(&mp3))
                {
                    if receipt
                        .provider
                        .as_deref()
                        .is_some_and(|provider| provider.contains("system"))
                    {
                        self.emit(ProgressEvent {
                            model_id: None,
                            voice: None,
                            fallback_used: receipt.fallback_used,
                            job_id: request.job_id.clone(),
                            state: "running".into(),
                            chapter_index: Some(source_index),
                            chapters_total: total,
                            chapters_completed: completed.load(Ordering::Acquire),
                            percent: 0.0,
                            engine: Some("system".into()),
                            message:
                                "Playing cached audio with occasional system-voice segments..."
                                    .into(),
                        });
                    }
                }
            }
            let stale_window_cancelled = std::sync::atomic::AtomicBool::new(false);
            let actual_providers = Mutex::new(Vec::<crate::tts_preferences::TtsSelection>::new());
            let audio_result = ensure_chapter_audio_with_options(
                &mp3,
                &request_key,
                self.execution_options.force_reprocess,
                |pending| {
                    eprintln!("synthesizing chapter {}/{}", position + 1, total);
                    let synthesis = if let Some(preferences) = &request.tts_preferences {
                        self.synthesize_preferences(
                            request,
                            preferences,
                            &text,
                            pending,
                            source_index,
                            language,
                            &stale_window_cancelled,
                            &actual_providers,
                            total,
                        )
                    } else if self.platform_tts.is_some()
                        && matches!(engine.as_str(), "edge" | "system")
                    {
                        self.synthesize_platform_policy(
                            &engine,
                            &text,
                            pending,
                            source_index,
                            request.voice.as_deref(),
                            language,
                            &stale_window_cancelled,
                            &system_notice_emitted,
                            &request.job_id,
                            total,
                            completed.load(Ordering::Acquire),
                        )
                    } else {
                        self.synthesize_with_timeout(
                            &engine,
                            &text,
                            pending,
                            source_index,
                            request.voice.as_deref(),
                            language,
                            request.piper_model.as_deref(),
                            request.piper_config.as_deref(),
                            &stale_window_cancelled,
                        )
                    };
                    if stale_window_cancelled.load(Ordering::Acquire) {
                        return Err(WorkerError::PlaybackWindowChanged);
                    }
                    synthesis?;
                    if self.cancel.is_cancelled()
                        || self.jobs.is_cancellation_requested(&request.job_id)?
                    {
                        return Err(WorkerError::Cancelled);
                    }
                    let used_selections = actual_providers.lock().expect("provider lock").clone();
                    let fallback_used = if request.tts_preferences.is_some() {
                        self.fallback_chapters
                            .lock()
                            .expect("fallback chapter lock")
                            .contains(&source_index)
                    } else {
                        engine == "edge"
                            && fs::read_to_string(pending.with_extension("provider"))
                                .ok()
                                .is_some_and(|provider| provider.contains("system"))
                    };
                    // Include actual provider roles in the initial completion receipt,
                    // before either durable chapter artifact is published.
                    cache::atomic_write_json(
                        pending.with_extension("tts-usage.json"),
                        &(used_selections, fallback_used),
                    )?;
                    Ok(())
                },
            );
            match audio_result {
                Err(WorkerError::PlaybackWindowChanged) => {
                    self.control
                        .as_ref()
                        .expect("playback-window cancellation requires conversion control")
                        .requeue(source_index)
                        .map_err(|error| WorkerError::Piper(error.to_string()))?;
                    return Ok(());
                }
                Err(error) => return Err(error),
                Ok(()) => {}
            }
            if !cached {
                let receipt_path = chapter_audio_receipt_path(&mp3);
                let mut receipt: ChapterAudioReceipt = cache::read_json(&receipt_path)?;
                if request.tts_preferences.is_some() {
                    receipt.used_selections =
                        actual_providers.lock().expect("provider lock").clone();
                    receipt.fallback_used = self
                        .fallback_chapters
                        .lock()
                        .expect("fallback chapter lock")
                        .contains(&source_index);
                }
                receipt.provider = if request.tts_preferences.is_some() {
                    Some(
                        actual_providers
                            .lock()
                            .expect("provider lock")
                            .iter()
                            .map(|selection| selection.engine.clone())
                            .collect::<Vec<_>>()
                            .join("+"),
                    )
                } else {
                    receipt.provider
                };
                if request.tts_preferences.is_none()
                    && engine == "edge"
                    && receipt
                        .provider
                        .as_deref()
                        .is_some_and(|provider| provider.contains("system"))
                {
                    receipt.fallback_used = true;
                }
                receipt.provider = receipt.provider.or_else(|| {
                    Some(
                        if engine == "system" {
                            "system"
                        } else if engine == "edge" && system_notice_emitted.load(Ordering::Acquire)
                        {
                            "edge+system"
                        } else {
                            &engine
                        }
                        .to_owned(),
                    )
                });
                cache::atomic_write_json(receipt_path, &receipt)?;
            }
            if let Some(control) = &self.control {
                if !control.chapter_is_in_playback_window(source_index) {
                    control
                        .requeue(source_index)
                        .map_err(|error| WorkerError::Piper(error.to_string()))?;
                    return Ok(());
                }
            }
            let name = mp3.file_name().unwrap().to_string_lossy().to_string();
            let chapters_completed = completed.fetch_add(1, Ordering::AcqRel) + 1;
            if let Some(sink) = &self.chapter_completed {
                sink(ChapterCompletionEvent {
                    job_id: request.job_id.clone(),
                    book_title: book.title.clone(),
                    book_author: book.author.clone(),
                    chapter_index: source_index,
                    chapters_total: total,
                    chapters_completed,
                    chapter_title: chapter.name.clone(),
                    filename: name.clone(),
                    audio_path: mp3.clone(),
                    text_chars: text.chars().count(),
                });
            }
            results.lock().unwrap().push((
                position,
                mp3,
                name.clone(),
                ChapterMetadata {
                    index: position + 1,
                    source_index,
                    title: chapter.name.clone(),
                    filename: name,
                    text_chars: text.chars().count(),
                },
            ));
            Ok(())
        };
        if let Some(control) = &self.control {
            while let Some(source_index) = control
                .take()
                .map_err(|error| WorkerError::Piper(error.to_string()))?
            {
                let Some((position, (_, chapter))) = chapters
                    .iter()
                    .enumerate()
                    .find(|(_, (candidate, _))| *candidate == source_index)
                else {
                    continue;
                };
                process_chapter(position, source_index, chapter)?;
            }
        } else {
            pool.install(|| {
                chapters.par_iter().enumerate().try_for_each(
                    |(position, (source_index, chapter))| {
                        process_chapter(position, *source_index, chapter)
                    },
                )
            })?;
        }
        let mut results = results.into_inner().unwrap();
        results.sort_by_key(|item| item.0);
        let files: Vec<_> = results
            .iter()
            .map(|(_, path, name, _)| (path.clone(), name.clone()))
            .collect();
        let manifest: Vec<_> = results
            .iter()
            .map(|(_, _, _, metadata)| metadata.clone())
            .collect();
        let output_text_chars: usize = manifest.iter().map(|chapter| chapter.text_chars).sum();
        if output_text_chars != source_text_chars {
            return Err(WorkerError::Piper(format!(
                "text coverage mismatch: source={source_text_chars}, output={output_text_chars}"
            )));
        }
        let cover = if cfg!(target_os = "android") {
            None
        } else {
            book.cover
                .as_ref()
                .map(|cover| {
                    let extension = match book.cover_mime.as_deref() {
                        Some("image/png") => "png",
                        Some("image/webp") => "webp",
                        _ => "jpg",
                    };
                    let name = format!("cover.{extension}");
                    let path = output_dir.join(&name);
                    std::fs::write(&path, cover).ok()?;
                    Some(name)
                })
                .flatten()
        };
        if let Some(cover_name) = &cover {
            let cover_path = output_dir.join(cover_name);
            for (_, path, _, _) in &results {
                audio::embed_cover(path, &cover_path)?;
                refresh_chapter_audio_receipt(path)?;
            }
        }
        let archive = output_dir.join(format!("{}.zip", sanitize(&book.title)));
        let archive_files = files
            .iter()
            .cloned()
            .chain(
                cover
                    .as_ref()
                    .map(|name| (output_dir.join(name), name.clone())),
            )
            .collect::<Vec<_>>();
        audio::create_archive(&archive, &archive_files)?;
        let output_name = archive.file_name().unwrap().to_string_lossy().to_string();
        let mut used_selections = Vec::new();
        let mut fallback_used = false;
        for (path, _) in &files {
            if let Ok(receipt) =
                cache::read_json::<ChapterAudioReceipt>(chapter_audio_receipt_path(path))
            {
                fallback_used |= receipt.fallback_used;
                for selection in receipt.used_selections {
                    if !used_selections.contains(&selection) {
                        used_selections.push(selection);
                    }
                }
            }
        }
        let result = OutputManifest {
            source_chapters_total: Some(source_chapters_total),
            tts_preferences: request.tts_preferences.clone(),
            used_selections,
            fallback_used,
            tts_policy_state: self
                .segment_policy
                .lock()
                .expect("segment policy lock")
                .clone(),

            job_id: request.job_id.clone(),
            title: book.title,
            author: book.author,
            chapters: manifest,
            archive: output_name,
            cover,
        };
        cache::atomic_write_json(output_dir.join("manifest.json"), &result)?;
        Ok(result)
    }
    fn synthesize(
        &self,
        engine: &str,
        text: &str,
        out: &Path,
        source_index: usize,
        voice: Option<&str>,
        language: Option<&str>,
        piper_model: Option<&Path>,
        piper_config: Option<&Path>,
        timeout: std::time::Duration,
        stale_window_cancelled: &std::sync::atomic::AtomicBool,
    ) -> Result<(), WorkerError> {
        if engine == "edge" {
            let voice = voice.unwrap_or_else(|| default_edge_voice(language));
            if let Some(sink) = self.streaming_chunk.as_ref() {
                use std::io::Write as _;
                let mut output = fs::File::create(out)?;
                let mut write_error = None;
                let result = run_edge_synthesis(
                    crate::tts::synthesize_with_reference_client_stream(
                        text,
                        voice,
                        Arc::clone(&self.adaptive),
                        self.telemetry.clone(),
                        |segment_index, bytes| {
                            if !dispatch_playback_chunk(
                                self.control.as_ref(),
                                Some(sink),
                                source_index,
                                segment_index,
                                bytes,
                                stale_window_cancelled,
                            ) {
                                return false;
                            }
                            if let Err(error) = output.write_all(bytes) {
                                write_error = Some(error);
                                return false;
                            }
                            true
                        },
                    ),
                    &self.cancel,
                    timeout,
                );
                if let Some(error) = write_error {
                    return Err(WorkerError::Io(error));
                }
                result?;
                return Ok(());
            }
            match run_edge_synthesis(
                crate::tts::synthesize_with_reference_client_chunks(
                    text,
                    voice,
                    Arc::clone(&self.adaptive),
                    self.telemetry.clone(),
                    |segment_index, bytes| {
                        dispatch_playback_chunk(
                            self.control.as_ref(),
                            self.streaming_chunk.as_ref(),
                            source_index,
                            segment_index,
                            bytes,
                            &stale_window_cancelled,
                        )
                    },
                ),
                &self.cancel,
                timeout,
            ) {
                Ok(bytes) => {
                    fs::write(out, bytes).map_err(|error| {
                        WorkerError::Edge(EdgeError::Transport(format!(
                            "failed to write synthesized audio {}: {error}",
                            out.display()
                        )))
                    })?;
                    return Ok(());
                }
                Err(error) => {
                    return Err(error);
                }
            }
        }
        if engine == "system" {
            return Err(WorkerError::PlatformTts(
                "No system speech adapter is installed for this conversion".into(),
            ));
        }
        self.synthesize_with_piper(text, out, piper_model, piper_config)
    }

    fn synthesize_platform_policy(
        &self,
        engine: &str,
        text: &str,
        out: &Path,
        source_index: usize,
        voice: Option<&str>,
        language: Option<&str>,
        stale: &std::sync::atomic::AtomicBool,
        system_notice_emitted: &std::sync::atomic::AtomicBool,
        job_id: &str,
        total: usize,
        completed: usize,
    ) -> Result<(), WorkerError> {
        use std::io::Write;
        let provider = self
            .platform_tts
            .as_ref()
            .expect("platform adapter installed");
        let started = std::sync::Mutex::new(std::time::Instant::now());
        let deadline = std::time::Duration::from_secs(30);
        let cancelled = || {
            self.cancel.is_cancelled()
                || started.lock().expect("deadline lock").elapsed() >= deadline
                || self
                    .control
                    .as_ref()
                    .is_some_and(|control| !control.chapter_is_in_playback_window(source_index))
        };
        let check = || {
            if self.cancel.is_cancelled() {
                Err(WorkerError::Cancelled)
            } else if self
                .control
                .as_ref()
                .is_some_and(|control| !control.chapter_is_in_playback_window(source_index))
            {
                stale.store(true, Ordering::Release);
                Err(WorkerError::PlaybackWindowChanged)
            } else if started.lock().expect("deadline lock").elapsed() >= deadline {
                Err(WorkerError::PlatformTts(
                    "chapter synthesis timed out".into(),
                ))
            } else {
                Ok(())
            }
        };
        let staging = tempfile::tempdir_in(out.parent().unwrap_or(Path::new(".")))?;
        let mut output = fs::File::create(out)?;
        let mut used_edge = false;
        let mut used_system = false;
        let mut chunk_index = 0usize;
        let dispatch = |bytes: &[u8], output: &mut fs::File, chunk_index: &mut usize| {
            check()?;
            if !dispatch_playback_chunk(
                self.control.as_ref(),
                self.streaming_chunk.as_ref(),
                source_index,
                *chunk_index,
                bytes,
                stale,
            ) {
                return Err(if stale.load(Ordering::Acquire) {
                    WorkerError::PlaybackWindowChanged
                } else {
                    WorkerError::Cancelled
                });
            }
            output.write_all(bytes)?;
            *chunk_index += 1;
            Ok(())
        };
        for segment in platform_tts::segments(text) {
            *started.lock().expect("deadline lock") = std::time::Instant::now();
            check()?;
            let edge = if engine == "system" {
                None
            } else {
                let remaining = std::time::Duration::from_secs(5);
                let synthesize = || {
                    run_edge_synthesis_checked(
                        crate::tts::synthesize_with_reference_client(
                            &segment,
                            voice.unwrap_or_else(|| default_edge_voice(language)),
                            Arc::clone(&self.adaptive),
                            self.telemetry.clone(),
                        ),
                        &cancelled,
                        remaining,
                    )
                };
                #[cfg(test)]
                let result = if let Some(edge) = &self.test_edge {
                    edge(&segment)
                } else {
                    synthesize()
                };
                #[cfg(not(test))]
                let result = synthesize();
                Some(result)
            };
            check()?;
            match edge {
                Some(Ok(bytes)) if platform_tts::validate_mp3(&bytes).is_ok() => {
                    self.consecutive_edge_failures.store(0, Ordering::Release);
                    used_edge = true;
                    dispatch(&bytes, &mut output, &mut chunk_index)?;
                }
                Some(Err(WorkerError::Cancelled))
                | Some(Err(WorkerError::Edge(EdgeError::Cancelled))) => {
                    return Err(WorkerError::Cancelled)
                }
                _ => {
                    if engine == "edge"
                        && self
                            .consecutive_edge_failures
                            .fetch_add(1, Ordering::AcqRel)
                            >= 2
                    {
                        return Err(WorkerError::PlatformTts("Edge is unavailable for consecutive segments. System speech is only an occasional fallback. Check your internet connection and retry.".into()));
                    }
                    let native_segments = platform_tts::native_segments(&segment, !used_system);
                    used_system = true;
                    if !system_notice_emitted.swap(true, Ordering::AcqRel) {
                        self.emit(ProgressEvent {
                            model_id: None,
                            voice: None,
                            fallback_used: engine == "edge",
                            job_id: job_id.into(),
                            state: "running".into(),
                            chapter_index: Some(source_index),
                            chapters_total: total,
                            chapters_completed: completed,
                            percent: if total == 0 {
                                0.0
                            } else {
                                completed as f64 * 100.0 / total as f64
                            },
                            engine: Some("system".into()),
                            message: "Using the system voice for this segment...".into(),
                        });
                    }
                    for native_text in native_segments {
                        let _guard = loop {
                            match self.platform_gate.try_lock() {
                                Ok(guard) => break guard,
                                Err(std::sync::TryLockError::Poisoned(_)) => {
                                    return Err(WorkerError::PlatformTts(
                                        "system speech lock poisoned".into(),
                                    ))
                                }
                                Err(std::sync::TryLockError::WouldBlock) => {
                                    if self.cancel.is_cancelled() {
                                        return Err(WorkerError::Cancelled);
                                    }
                                    if self.control.as_ref().is_some_and(|control| {
                                        !control.chapter_is_in_playback_window(source_index)
                                    }) {
                                        stale.store(true, Ordering::Release);
                                        return Err(WorkerError::PlaybackWindowChanged);
                                    }
                                    std::thread::sleep(std::time::Duration::from_millis(25));
                                }
                            }
                        };
                        *started.lock().expect("deadline lock") = std::time::Instant::now();
                        check()?;
                        let wav = staging.path().join("segment.wav");
                        let synthesis = provider.synthesize_wav(
                            &native_text,
                            language.unwrap_or("pt-BR"),
                            &wav,
                            &cancelled,
                        );
                        check()?;
                        synthesis.map_err(WorkerError::PlatformTts)?;
                        let bytes = platform_tts::encode_wav(&fs::read(&wav)?)
                            .map_err(WorkerError::PlatformTts)?;
                        dispatch(&bytes, &mut output, &mut chunk_index)?;
                    }
                }
            }
        }
        output.sync_all()?;
        check()?;
        fs::write(
            out.with_extension("provider"),
            if used_edge && used_system {
                "edge+system"
            } else if used_system {
                "system"
            } else {
                "edge"
            },
        )?;
        Ok(())
    }

    fn selection_model_paths(
        &self,
        request: &ConversionRequest,
        selection: &crate::tts_preferences::TtsSelection,
    ) -> (PathBuf, PathBuf) {
        let id = selection
            .model_id
            .as_deref()
            .unwrap_or(crate::tts_preferences::FABER_MODEL_ID);
        if let Some(root) = &request.models_root {
            let directory = root.join(id);
            return (
                directory.join("model.onnx"),
                directory.join("model.onnx.json"),
            );
        }
        let model = request.piper_model.clone().unwrap_or_else(|| {
            self.config
                .paths
                .piper_models_dir
                .join(format!("{id}.onnx"))
        });
        let config = request
            .piper_config
            .clone()
            .unwrap_or_else(|| model.with_extension("onnx.json"));
        (model, config)
    }

    fn synthesize_preferences(
        &self,
        request: &ConversionRequest,
        preferences: &crate::tts_preferences::TtsPreferences,
        text: &str,
        out: &Path,
        source_index: usize,
        language: Option<&str>,
        stale: &std::sync::atomic::AtomicBool,
        providers: &Mutex<Vec<crate::tts_preferences::TtsSelection>>,
        total: usize,
    ) -> Result<(), WorkerError> {
        use std::io::Write;
        preferences.validate(language).map_err(WorkerError::Piper)?;
        let staging = tempfile::tempdir()?;
        let mut output = fs::File::create(out)?;
        let mut policy = self.segment_policy.lock().expect("segment policy lock");
        // The first short utterance becomes playable before the rest of the chapter.
        let segments = platform_tts::segments(text);
        for (index, segment) in segments.iter().enumerate() {
            if self.cancel.is_cancelled() {
                return Err(WorkerError::Cancelled);
            }
            if stale.load(Ordering::Acquire) {
                return Err(WorkerError::PlaybackWindowChanged);
            }
            let path = staging.path().join(format!("{index}.mp3"));
            let synthesize_unvalidated =
                |selection: &crate::tts_preferences::TtsSelection| -> Result<Vec<u8>, WorkerError> {
                    if self.cancel.is_cancelled() {
                        return Err(WorkerError::Cancelled);
                    }
                    if stale.load(Ordering::Acquire) {
                        return Err(WorkerError::PlaybackWindowChanged);
                    }
                    if selection.engine == "system" {
                        let adapter = self.platform_tts.as_ref().ok_or_else(|| {
                            WorkerError::PlatformTts("No installed system speech adapter".into())
                        })?;
                        let wav = path.with_extension("wav");
                        let cancelled =
                            || self.cancel.is_cancelled() || stale.load(Ordering::Acquire);
                        adapter
                            .synthesize_wav(segment, language.unwrap_or("pt-BR"), &wav, &cancelled)
                            .map_err(WorkerError::PlatformTts)?;
                        return platform_tts::encode_wav(&fs::read(wav)?)
                            .map_err(WorkerError::PlatformTts);
                    }
                    if selection.engine == "edge" {
                        #[cfg(test)]
                        if let Some(edge) = &self.test_edge {
                            return edge(segment);
                        }
                        return run_preference_edge_synthesis(
                            crate::tts::synthesize_with_reference_client(
                                segment,
                                selection
                                    .voice
                                    .as_deref()
                                    .unwrap_or_else(|| default_edge_voice(language)),
                                Arc::clone(&self.adaptive),
                                self.telemetry.clone(),
                            ),
                            &self.cancel,
                            segment.len(),
                        );
                    }
                    let (model, config) = self.selection_model_paths(request, selection);
                    let wav = path.with_extension("wav");
                    self.synthesize_with_piper(segment, &wav, Some(&model), Some(&config))?;
                    platform_tts::encode_wav(&fs::read(wav)?).map_err(WorkerError::PlatformTts)
                };
            let synthesize =
                |selection: &crate::tts_preferences::TtsSelection| -> Result<Vec<u8>, WorkerError> {
                    let bytes = synthesize_unvalidated(selection)?;
                    // Native inference may finish after cancellation was requested.
                    // Never deliver those bytes or start a secondary provider afterward.
                    if self.cancel.is_cancelled() {
                        return Err(WorkerError::Cancelled);
                    }
                    if stale.load(Ordering::Acquire) {
                        return Err(WorkerError::PlaybackWindowChanged);
                    }
                    platform_tts::validate_mp3(&bytes).map_err(WorkerError::PlatformTts)?;
                    Ok(bytes)
                };
            let (selection, bytes, fallback_used) = match synthesize(&preferences.primary) {
                Ok(bytes) => {
                    policy.primary_succeeded();
                    (&preferences.primary, bytes, false)
                }
                Err(error) => {
                    if stale.load(Ordering::Acquire)
                        || matches!(error, WorkerError::PlaybackWindowChanged)
                    {
                        return Err(WorkerError::PlaybackWindowChanged);
                    }
                    if self.cancel.is_cancelled()
                        || matches!(
                            error,
                            WorkerError::Cancelled | WorkerError::Edge(EdgeError::Cancelled)
                        )
                    {
                        return Err(WorkerError::Cancelled);
                    }
                    policy
                        .primary_failed(false, preferences.secondary.is_some())
                        .map_err(|policy_error| {
                            WorkerError::Piper(format!("{policy_error}: {error}"))
                        })?;
                    let secondary = preferences.secondary.as_ref().expect("checked secondary");
                    (secondary, synthesize(secondary)?, true)
                }
            };
            if !dispatch_playback_chunk(
                self.control.as_ref(),
                self.streaming_chunk.as_ref(),
                source_index,
                index,
                &bytes,
                stale,
            ) {
                return Err(if stale.load(Ordering::Acquire) {
                    WorkerError::PlaybackWindowChanged
                } else {
                    WorkerError::Cancelled
                });
            }
            output.write_all(&bytes)?;
            if fallback_used {
                self.fallback_chapters
                    .lock()
                    .expect("fallback chapter lock")
                    .insert(source_index);
            }
            let mut actual_selection = selection.clone();
            if actual_selection.engine == "edge" && actual_selection.voice.is_none() {
                actual_selection.voice = Some(default_edge_voice(language).into());
            }
            let mut used = providers.lock().expect("provider lock");
            if !used.contains(&actual_selection) {
                used.push(actual_selection.clone());
            }
            self.emit(ProgressEvent {
                job_id: request.job_id.clone(),
                state: "running".into(),
                chapter_index: Some(source_index),
                chapters_total: total,
                chapters_completed: 0,
                percent: 0.0,
                engine: Some(selection.engine.clone()),
                model_id: selection.model_id.clone(),
                voice: actual_selection.voice.clone(),
                fallback_used,
                message: format!("Using {} for segment {}", selection.engine, index + 1),
            });
        }
        output.sync_all()?;
        Ok(())
    }

    fn synthesize_with_piper(
        &self,
        text: &str,
        out: &Path,
        piper_model: Option<&Path>,
        piper_config: Option<&Path>,
    ) -> Result<(), WorkerError> {
        let runtime_status = piper::piper_runtime_status();
        if cfg!(target_os = "android")
            && (!runtime_status.runtime_loaded || !runtime_status.abi_compatible)
        {
            return Err(WorkerError::Piper(
                "Piper is disabled on Android; Edge TTS is required".into(),
            ));
        }
        if let Some(model) = &self.piper_model {
            return model
                .synthesize(text, out, &self.cancel)
                .map_err(|error| WorkerError::Piper(error.to_string()));
        }
        let model = piper_model.map(Path::to_path_buf).unwrap_or_else(|| {
            self.config
                .paths
                .piper_models_dir
                .join("pt_BR-faber-medium.onnx")
        });
        let model = if model.is_file() {
            model
        } else {
            return Err(WorkerError::Piper(format!(
                "Piper model is unavailable at {}",
                model.display()
            )));
        };
        let config = piper_config
            .map(Path::to_path_buf)
            .unwrap_or_else(|| model.with_extension("onnx.json"));
        let mut c = PiperConfig::new(model, config);
        c.chunk_chars = std::env::var("PIPER_CHUNK_CHARS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(5_000);
        piper::synthesize(&c, text, out, &self.cancel)
            .map(|_| ())
            .map_err(|e| WorkerError::Piper(e.to_string()))
    }
    fn synthesize_with_timeout(
        &self,
        engine: &str,
        text: &str,
        out: &Path,
        source_index: usize,
        voice: Option<&str>,
        language: Option<&str>,
        piper_model: Option<&Path>,
        piper_config: Option<&Path>,
        stale_window_cancelled: &std::sync::atomic::AtomicBool,
    ) -> Result<(), WorkerError> {
        let timeout_secs = std::env::var("RUST_CHAPTER_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(if cfg!(target_os = "android") {
                300
            } else {
                180
            });
        let timeout = std::time::Duration::from_secs(timeout_secs);
        if engine == "edge" {
            return self.synthesize(
                engine,
                text,
                out,
                source_index,
                voice,
                language,
                piper_model,
                piper_config,
                timeout,
                stale_window_cancelled,
            );
        }
        let result = std::thread::scope(|scope| {
            let handle = scope.spawn(|| {
                self.synthesize(
                    engine,
                    text,
                    out,
                    source_index,
                    voice,
                    language,
                    piper_model,
                    piper_config,
                    timeout,
                    stale_window_cancelled,
                )
            });
            let started = std::time::Instant::now();
            while !handle.is_finished() {
                if self.cancel.is_cancelled()
                    || started.elapsed() >= std::time::Duration::from_secs(timeout_secs)
                {
                    return Err(if engine == "edge" {
                        WorkerError::Edge(EdgeError::Transport(
                            "chapter synthesis timed out".into(),
                        ))
                    } else {
                        WorkerError::Piper("chapter synthesis timed out".into())
                    });
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            handle.join().unwrap_or_else(|_| {
                Err(if engine == "edge" {
                    WorkerError::Edge(EdgeError::Transport("synthesis thread panicked".into()))
                } else {
                    WorkerError::Piper("synthesis thread panicked".into())
                })
            })
        });
        result
    }
    #[allow(dead_code)]
    fn emit(&self, event: ProgressEvent) {
        if let Some(sink) = &self.progress {
            sink(event)
        }
    }
}

fn chapter_selection_matches(value: &str, chapter_index: &str, position: usize) -> bool {
    value == chapter_index
        || value
            .strip_prefix("position:")
            .unwrap_or(value)
            .parse::<usize>()
            .map(|index| index == position)
            .unwrap_or(false)
}

fn dispatch_playback_chunk(
    control: Option<&ConversionControl>,
    sink: Option<&StreamingChunkSink>,
    chapter_index: usize,
    chunk_index: usize,
    bytes: &[u8],
    stale_window_cancelled: &std::sync::atomic::AtomicBool,
) -> bool {
    if control.is_some_and(|control| !control.chapter_is_in_playback_window(chapter_index)) {
        stale_window_cancelled.store(true, Ordering::Release);
        return false;
    }
    sink.is_none_or(|sink| sink(chapter_index, chunk_index, bytes))
}

fn cached_chapter_text(path: &Path, expected: &str) -> Result<String, WorkerError> {
    if let Ok(text) = cache::read_json::<String>(path) {
        if text == expected {
            return Ok(text);
        }
    }
    cache::atomic_write_json(path, expected)?;
    Ok(expected.to_owned())
}

fn chapter_audio_request_key(
    source_key: &str,
    chapter_index: &str,
    text: &str,
    engine: &str,
    voice: Option<&str>,
    language: Option<&str>,
) -> Result<String, WorkerError> {
    let text_key = cache::sha256_bytes(text.as_bytes());
    let request =
        serde_json::to_vec(&(source_key, chapter_index, text_key, engine, voice, language))
            .map_err(cache::CacheError::from)?;
    Ok(cache::sha256_bytes(&request))
}

#[derive(Debug, Serialize, Deserialize)]
struct ChapterAudioReceipt {
    version: u8,
    fallback_used: bool,
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    used_selections: Vec<crate::tts_preferences::TtsSelection>,
    request_key: String,
    audio_sha256: String,
    size: u64,
}

fn chapter_audio_receipt_path(output: &Path) -> PathBuf {
    output.with_extension("mp3.complete.json")
}

fn chapter_audio_is_complete(output: &Path, request_key: &str) -> bool {
    let Ok(receipt) = cache::read_json::<ChapterAudioReceipt>(chapter_audio_receipt_path(output))
    else {
        return false;
    };
    if receipt.version != 2 || receipt.request_key != request_key || receipt.size == 0 {
        return false;
    }
    fs::metadata(output).is_ok_and(|metadata| metadata.is_file() && metadata.len() == receipt.size)
        && cache::sha256_file(output).is_ok_and(|hash| hash == receipt.audio_sha256)
}

fn refresh_chapter_audio_receipt(output: &Path) -> Result<(), WorkerError> {
    let receipt_path = chapter_audio_receipt_path(output);
    let mut receipt: ChapterAudioReceipt = cache::read_json(&receipt_path)?;
    receipt.size = fs::metadata(output)?.len();
    receipt.audio_sha256 = cache::sha256_file(output)?;
    cache::atomic_write_json(receipt_path, &receipt)?;
    Ok(())
}

fn ensure_chapter_audio(
    output: &Path,
    request_key: &str,
    synthesize: impl FnOnce(&Path) -> Result<(), WorkerError>,
) -> Result<(), WorkerError> {
    ensure_chapter_audio_with_options(output, request_key, false, synthesize)
}

fn ensure_chapter_audio_with_options(
    output: &Path,
    request_key: &str,
    force: bool,
    synthesize: impl FnOnce(&Path) -> Result<(), WorkerError>,
) -> Result<(), WorkerError> {
    if !force && chapter_audio_is_complete(output, request_key) {
        return Ok(());
    }
    let parent = output
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new()
        .prefix(".chapter-audio-")
        .tempdir_in(parent)?;
    let pending = staging.path().join("chapter.mp3");
    synthesize(&pending)?;
    if force {
        audio::validate_audio(&pending, 100)?;
    }
    let metadata = fs::metadata(&pending)?;
    if !metadata.is_file() || metadata.len() == 0 {
        return Err(WorkerError::Audio(audio::AudioError::Validation(
            "synthesis produced an empty audio artifact".into(),
        )));
    }
    let usage_path = pending.with_extension("tts-usage.json");
    let (used_selections, fallback_used) = if usage_path.is_file() {
        cache::read_json::<(Vec<crate::tts_preferences::TtsSelection>, bool)>(&usage_path)?
    } else {
        (Vec::new(), false)
    };
    let receipt = ChapterAudioReceipt {
        used_selections,
        version: 2,
        fallback_used,
        provider: fs::read_to_string(pending.with_extension("provider")).ok(),
        request_key: request_key.to_owned(),
        audio_sha256: cache::sha256_file(&pending)?,
        size: metadata.len(),
    };
    // Only publish a successfully finished synthesis. A synthesis failure leaves
    // the previous artifact and its completion receipt intact.
    let pending_receipt = staging.path().join("complete.json");
    cache::atomic_write_json(&pending_receipt, &receipt)?;
    fs::rename(&pending, output)?;
    fs::rename(pending_receipt, chapter_audio_receipt_path(output))?;
    Ok(())
}

fn run_edge_synthesis_checked<T, F>(
    synthesis: F,
    cancelled: &(dyn Fn() -> bool + Sync),
    timeout: std::time::Duration,
) -> Result<T, WorkerError>
where
    F: std::future::Future<Output = Result<T, EdgeError>>,
{
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let result = runtime.block_on(async {
        let stopped = async { loop { if cancelled() { return; } tokio::time::sleep(std::time::Duration::from_millis(50)).await; } };
        tokio::select! { biased;
            _ = stopped => Err(WorkerError::Cancelled),
            result = tokio::time::timeout(timeout, synthesis) => result.map_err(|_| WorkerError::Edge(EdgeError::Timeout))?.map_err(WorkerError::Edge),
        }
    });
    runtime.shutdown_background();
    result
}

fn run_preference_edge_synthesis<T, F>(
    synthesis: F,
    cancel: &CancellationToken,
    text_bytes: usize,
) -> Result<T, WorkerError>
where
    F: std::future::Future<Output = Result<T, EdgeError>>,
{
    run_edge_synthesis(
        synthesis,
        cancel,
        crate::tts::reference_synthesis_timeout_for_text(text_bytes),
    )
}

fn run_edge_synthesis<T, F>(
    synthesis: F,
    cancel: &CancellationToken,
    timeout: std::time::Duration,
) -> Result<T, WorkerError>
where
    F: std::future::Future<Output = Result<T, EdgeError>>,
{
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime.block_on(async {
            let cancelled = async {
                loop {
                    if cancel.is_cancelled() {
                        return;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
            };
            tokio::select! {
                biased;
                _ = cancelled => Err(WorkerError::Cancelled),
                result = tokio::time::timeout(timeout, synthesis) => {
                    match result {
                        Ok(result) => result.map_err(WorkerError::Edge),
                        Err(_) => Err(WorkerError::Edge(EdgeError::Transport(
                            "chapter synthesis timed out".into(),
                        ))),
                    }
                }
            }
        })
    }))
    .unwrap_or_else(|_| {
        Err(WorkerError::Edge(EdgeError::Transport(
            "synthesis thread panicked".into(),
        )))
    });
    // DNS resolution can use Tokio's blocking pool. Dropping the runtime would
    // wait for those calls even after the network future has been cancelled.
    runtime.shutdown_background();
    result
}

fn detect_language(text: &str) -> Option<&'static str> {
    let lower = text.to_ascii_lowercase();
    let markers = [
        ("pt-BR", [" que ", " não ", " uma ", " para ", " você "]),
        ("it-IT", [" che ", " non ", " una ", " per ", " della "]),
        ("es-ES", [" que ", " no ", " una ", " para ", " los "]),
        ("en-US", [" the ", " and ", " not ", " this ", " with "]),
    ];
    markers
        .into_iter()
        .max_by_key(|(_, words)| words.iter().filter(|word| lower.contains(**word)).count())
        .and_then(|(language, words)| {
            (words.iter().filter(|word| lower.contains(**word)).count() >= 2).then_some(language)
        })
}

fn default_edge_voice(language: Option<&str>) -> &'static str {
    match language.unwrap_or_default().to_ascii_lowercase().as_str() {
        "pt" | "pt-br" | "pt_br" => "pt-BR-FranciscaNeural",
        "it" | "it-it" => "it-IT-ElsaNeural",
        "es" | "es-es" | "es-mx" => "es-ES-ElviraNeural",
        "en" | "en-us" | "en-gb" => "en-US-GuyNeural",
        _ => "en-US-EmmaMultilingualNeural",
    }
}

fn select_engine(request: Option<&str>, config: &AppConfig) -> String {
    match request
        .unwrap_or(&config.engine)
        .to_ascii_lowercase()
        .as_str()
    {
        "piper" => "piper".into(),
        "system" => "system".into(),
        _ => "edge".into(),
    }
}
fn sanitize(value: &str) -> String {
    let mut s = value
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, '-' | '_' | ' ' | '.') {
                c
            } else {
                '_'
            }
        })
        .collect::<String>();
    s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.is_empty() {
        "book".into()
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn empty_typed_manifest_metadata_preserves_legacy_shape_and_nondefault_round_trip() {
        let legacy = serde_json::json!({
            "jobId": "legacy", "title": "Book", "author": "Author", "chapters": [],
            "archive": "book.zip", "cover": null,
        });
        let mut manifest: OutputManifest = serde_json::from_value(legacy.clone()).unwrap();
        assert_eq!(serde_json::to_value(&manifest).unwrap(), legacy);
        let primary = crate::tts_preferences::TtsSelection {
            engine: "system".into(),
            model_id: None,
            voice: None,
        };
        manifest.tts_preferences = Some(crate::tts_preferences::TtsPreferences {
            primary: primary.clone(),
            secondary: None,
            allow_online_fallback: false,
        });
        manifest.used_selections.push(primary);
        manifest.fallback_used = true;
        manifest
            .tts_policy_state
            .primary_failed(false, true)
            .unwrap();
        let encoded = serde_json::to_value(&manifest).unwrap();
        assert_eq!(encoded["fallbackUsed"], true);
        assert_eq!(encoded["usedSelections"][0]["engine"], "system");
        assert_eq!(encoded["ttsPolicyState"]["consecutive_failures"], 1);
        assert_eq!(
            serde_json::from_value::<OutputManifest>(encoded).unwrap(),
            manifest
        );
    }

    use super::*;

    #[test]
    fn performance_override_still_respects_configuration_and_platform_caps() {
        let fast = ExecutionOptions {
            max_performance: true,
            ..ExecutionOptions::default()
        };
        assert_eq!(
            ExecutionOptions::default().chapter_parallelism(true, 8, 8, 2),
            1
        );
        assert_eq!(fast.chapter_parallelism(true, 8, 8, 2), 2);
        assert_eq!(fast.chapter_parallelism(true, 1, 8, 2), 1);
        assert_eq!(fast.chapter_parallelism(true, 8, 1, 2), 1);
        assert_eq!(fast.chapter_parallelism(true, 8, 8, 1), 1);
    }

    #[test]
    fn forced_replacement_preserves_audio_and_receipt_on_failure_or_cancellation() {
        let fixture = tempfile::tempdir().unwrap();
        let output = fixture.path().join("selected.mp3");
        ensure_chapter_audio(&output, "identity", |pending| {
            fs::write(pending, test_system_wav())?;
            Ok(())
        })
        .unwrap();
        let prior = fs::read(&output).unwrap();
        let receipt = fs::read(chapter_audio_receipt_path(&output)).unwrap();
        for cancel in [false, true] {
            let result = ensure_chapter_audio_with_options(&output, "identity", true, |pending| {
                fs::write(pending, b"partial invalid audio")?;
                if cancel {
                    Err(WorkerError::Cancelled)
                } else {
                    Ok(())
                }
            });
            assert!(result.is_err());
            assert_eq!(fs::read(&output).unwrap(), prior);
            assert_eq!(
                fs::read(chapter_audio_receipt_path(&output)).unwrap(),
                receipt
            );
        }
        ensure_chapter_audio_with_options(&output, "identity", true, |pending| {
            fs::write(pending, test_system_wav_at_rate(16_000))?;
            Ok(())
        })
        .unwrap();
        assert_ne!(fs::read(&output).unwrap(), prior);
        assert!(chapter_audio_is_complete(&output, "identity"));
        assert_eq!(fs::read_dir(fixture.path()).unwrap().count(), 2);
    }

    struct TestSystem {
        texts: Arc<Mutex<Vec<String>>>,
    }
    impl PlatformTts for TestSystem {
        fn synthesize_wav(
            &self,
            text: &str,
            _: &str,
            output: &Path,
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), String> {
            if cancelled() {
                return Err("cancelled".into());
            }
            self.texts.lock().unwrap().push(text.into());
            fs::write(output, test_system_wav()).map_err(|e| e.to_string())
        }
    }
    fn test_system_wav() -> Vec<u8> {
        test_system_wav_at_rate(22050)
    }
    fn test_system_wav_at_rate(rate: u32) -> Vec<u8> {
        let samples: Vec<i16> = (0..rate / 8)
            .map(|i| {
                ((i as f64 * 440.0 * std::f64::consts::TAU / rate as f64).sin() * 4000.0) as i16
            })
            .collect();
        let len = (samples.len() * 2) as u32;
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + len).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&rate.to_le_bytes());
        wav.extend_from_slice(&(rate * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&len.to_le_bytes());
        for sample in samples {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        wav
    }
    fn preference_test_request() -> ConversionRequest {
        ConversionRequest {
            input: PathBuf::new(),
            job_id: "policy-test".into(),
            engine: None,
            voice: None,
            language: Some("pt-BR".into()),
            tts_preferences: None,
            models_root: None,
            piper_model: None,
            piper_config: None,
            chapter_indices: None,
            no_parallel: true,
        }
    }
    #[test]
    fn typed_playback_window_change_does_not_count_as_provider_failure() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let mut worker = ConversionWorker::new(config).unwrap();
        let stale = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let changed = stale.clone();
        worker.test_edge = Some(Arc::new(move |_| {
            changed.store(true, Ordering::Release);
            Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
        }));
        let mut preferences = crate::tts_preferences::TtsPreferences::default();
        preferences.primary.engine = "edge".into();
        preferences.primary.model_id = None;
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            "Uma frase curta.",
            &temp.path().join("stale.mp3"),
            0,
            Some("pt-BR"),
            &stale,
            &Mutex::new(Vec::new()),
            1,
        );
        assert!(matches!(result, Err(WorkerError::PlaybackWindowChanged)));
        assert_eq!(
            serde_json::to_value(worker.segment_policy.lock().unwrap().clone()).unwrap()
                ["consecutive_failures"],
            0
        );
    }

    #[test]
    fn typed_provider_returning_audio_after_cancellation_never_publishes_or_falls_back() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        let cancel = worker.cancel.clone();
        worker.test_edge = Some(Arc::new(move |_| {
            cancel.cancel();
            Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
        }));
        worker = worker.with_streaming_chunks(Arc::new(|_, _, _| {
            panic!("cancelled audio must not be delivered")
        }));
        let preferences = TtsPreferences {
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: Some(TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
            }),
            allow_online_fallback: false,
        };
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            "Uma frase curta.",
            &temp.path().join("cancelled.mp3"),
            0,
            Some("pt-BR"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
        );
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert!(spoken.lock().unwrap().is_empty());
    }

    #[test]
    fn typed_policy_stops_third_failure_and_cancellation_never_falls_back() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            Vec::<(String, String)>::new(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Edge(EdgeError::Timeout))));
        let preferences = TtsPreferences {
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: Some(TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
            }),
            allow_online_fallback: false,
        };
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            &"A sentence. ".repeat(300),
            &temp.path().join("outage.mp3"),
            0,
            Some("pt-BR"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
        );
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("three consecutive"));
        assert_eq!(spoken.lock().unwrap().len(), 2);
        spoken.lock().unwrap().clear();
        worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Cancelled)));
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            "A sentence.",
            &temp.path().join("cancel.mp3"),
            0,
            Some("pt-BR"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
        );
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert!(spoken.lock().unwrap().is_empty());
    }

    #[test]
    fn explicit_preferences_retry_primary_after_invalid_audio_and_publish_mixed_segments() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            Vec::<(String, String)>::new(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        let attempts = Arc::new(AtomicUsize::new(0));
        let count = attempts.clone();
        worker.test_edge = Some(Arc::new(move |_| {
            if count.fetch_add(1, Ordering::AcqRel) == 0 {
                Ok(b"malformed primary MP3".to_vec())
            } else {
                Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
            }
        }));
        let preferences = TtsPreferences {
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: Some("pt-BR-FranciscaNeural".into()),
            },
            secondary: Some(TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
            }),
            allow_online_fallback: false,
        };
        let text = "A sentence for voice selection. ".repeat(40);
        let providers = Mutex::new(Vec::new());
        let out = temp.path().join("mixed.mp3");
        worker
            .synthesize_preferences(
                &preference_test_request(),
                &preferences,
                &text,
                &out,
                0,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &providers,
                1,
            )
            .unwrap();
        assert!(attempts.load(Ordering::Acquire) > 1);
        assert_eq!(spoken.lock().unwrap().len(), 1);
        assert_eq!(
            providers
                .lock()
                .unwrap()
                .iter()
                .map(|s| s.engine.as_str())
                .collect::<Vec<_>>(),
            vec!["system", "edge"]
        );
        platform_tts::validate_mp3(&fs::read(out).unwrap()).unwrap();
    }
    #[test]
    fn strict_preferences_do_not_use_registered_system_fallback() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            Vec::<(String, String)>::new(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        worker.test_edge = Some(Arc::new(|_| {
            Err(WorkerError::Piper("fixture voice failed".into()))
        }));
        let preferences = TtsPreferences {
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: None,
            allow_online_fallback: false,
        };
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            "A sentence.",
            &temp.path().join("strict.mp3"),
            0,
            Some("pt"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
        );
        let error = result.unwrap_err().to_string();
        assert!(error.contains("no secondary voice is enabled"));
        assert!(error.contains("fixture voice failed"));
        assert!(spoken.lock().unwrap().is_empty());
    }

    #[test]
    fn fallback_resumes_failed_segment_without_replaying_and_retries_edge() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }));
        let requests = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&requests);
        let audio = platform_tts::encode_wav(&test_system_wav_at_rate(24000)).unwrap();
        worker.test_edge = Some(Arc::new(move |_| {
            if !matches!(count.fetch_add(1, Ordering::AcqRel), 1 | 3) {
                Ok(audio.clone())
            } else {
                Err(WorkerError::Edge(EdgeError::Timeout))
            }
        }));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let received = Arc::clone(&delivered);
        worker = worker.with_streaming_chunks(Arc::new(move |_, index, bytes| {
            assert!(platform_tts::validate_mp3(bytes).is_ok());
            received.lock().unwrap().push(index);
            true
        }));
        let text = "A sentence to preserve every word. ".repeat(70);
        let pieces = platform_tts::segments(&text);
        let native = std::sync::atomic::AtomicBool::new(false);
        worker
            .synthesize_platform_policy(
                "edge",
                &text,
                &temp.path().join("audio.mp3"),
                0,
                None,
                Some("en-US"),
                &std::sync::atomic::AtomicBool::new(false),
                &native,
                "job",
                1,
                0,
            )
            .unwrap();
        assert_eq!(requests.load(Ordering::Acquire), pieces.len());
        let native_texts = spoken.lock().unwrap();
        assert_eq!(
            native_texts.join(" "),
            [pieces[1].as_str(), pieces[3].as_str()].join(" ")
        );
        assert!(native_texts[0].chars().count() <= 60);
        assert!(native_texts
            .iter()
            .skip(1)
            .all(|text| text.chars().count() <= 240));
        let expected_chunk_count = pieces.len() - 2 + native_texts.len();
        drop(native_texts);
        assert_eq!(
            *delivered.lock().unwrap(),
            (0..expected_chunk_count).collect::<Vec<_>>()
        );
        assert!(native.load(Ordering::Acquire));
        let artifact = temp.path().join("audio.mp3");
        audio::validate_audio(&artifact, 100).unwrap();
        assert_eq!(audio::probe_sample_rate(&artifact).unwrap(), 24000);
        assert_eq!(
            fs::read_to_string(temp.path().join("audio.provider")).unwrap(),
            "edge+system"
        );
    }
    #[test]
    fn third_consecutive_edge_failure_stops_before_more_native_speech() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }));
        let requests = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&requests);
        worker.test_edge = Some(Arc::new(move |_| {
            count.fetch_add(1, Ordering::AcqRel);
            Err(WorkerError::Edge(EdgeError::Timeout))
        }));
        let text = "A sentence that must not become a fully offline book. ".repeat(40);
        let pieces = platform_tts::segments(&text);
        let error = worker
            .synthesize_platform_policy(
                "edge",
                &text,
                &temp.path().join("audio.mp3"),
                0,
                None,
                None,
                &std::sync::atomic::AtomicBool::new(false),
                &std::sync::atomic::AtomicBool::new(false),
                "job",
                1,
                0,
            )
            .unwrap_err();
        assert!(
            matches!(error, WorkerError::PlatformTts(ref message) if message.contains("Check your internet"))
        );
        assert_eq!(requests.load(Ordering::Acquire), 3);
        assert_eq!(spoken.lock().unwrap().join(" "), pieces[..2].join(" "));
        assert!(!temp.path().join("audio.provider").exists());
    }

    #[test]
    fn persistent_edge_outage_fails_real_job_without_publishing_partial_audio() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("book.epub");
        platform_test_book_with_text(
            &input,
            &"Uma frase de teste sem conversão integral offline. ".repeat(40),
        );
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let output = config.paths.output_dir.join("outage-job");
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }));
        worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Edge(EdgeError::Timeout))));
        let request = ConversionRequest {
            tts_preferences: None,
            models_root: None,
            input,
            job_id: "outage-job".into(),
            engine: Some("edge".into()),
            voice: None,
            language: Some("pt-BR".into()),
            piper_model: None,
            piper_config: None,
            chapter_indices: None,
            no_parallel: true,
        };
        assert!(matches!(
            worker.run(request),
            Err(WorkerError::PlatformTts(_))
        ));
        assert_eq!(
            worker.jobs.load("outage-job").unwrap().state,
            JobState::Failed
        );
        assert_eq!(
            worker.jobs.list().unwrap().len(),
            1,
            "Saved request options must not corrupt the job-record index"
        );
        assert_eq!(
            fs::read_dir(output).unwrap().count(),
            0,
            "Interrupted chapter cannot publish a partial MP3 or receipt"
        );
        assert!(!spoken.lock().unwrap().is_empty());
    }

    #[test]
    fn forced_system_delivers_bounded_utterances_before_synthesizing_next_chunk() {
        struct BoundedSystem {
            spoken: Arc<Mutex<Vec<String>>>,
            delivered: Arc<Mutex<Vec<usize>>>,
        }
        impl PlatformTts for BoundedSystem {
            fn synthesize_wav(
                &self,
                text: &str,
                _: &str,
                output: &Path,
                cancelled: &(dyn Fn() -> bool + Sync),
            ) -> Result<(), String> {
                assert!(!cancelled());
                let mut spoken = self.spoken.lock().unwrap();
                assert!(text.chars().count() <= if spoken.is_empty() { 60 } else { 240 });
                assert_eq!(
                    self.delivered.lock().unwrap().len(),
                    spoken.len(),
                    "Previous native audio must play before the next synthesis starts"
                );
                spoken.push(text.into());
                fs::write(output, test_system_wav()).map_err(|error| error.to_string())
            }
        }
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let received = Arc::clone(&delivered);
        let worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(BoundedSystem {
                spoken: Arc::clone(&spoken),
                delivered: Arc::clone(&delivered),
            }))
            .with_streaming_chunks(Arc::new(move |_, index, bytes| {
                platform_tts::validate_mp3(bytes).unwrap();
                received.lock().unwrap().push(index);
                true
            }));
        let text = "Uma frase para preservar todo o conteúdo sem repetição. ".repeat(24);
        worker
            .synthesize_platform_policy(
                "system",
                &text,
                &temp.path().join("audio.mp3"),
                0,
                None,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &std::sync::atomic::AtomicBool::new(false),
                "job",
                1,
                0,
            )
            .unwrap();
        let spoken = spoken.lock().unwrap();
        assert_eq!(spoken.join(" "), text.trim());
        assert!(spoken.len() >= 6);
        assert_eq!(
            *delivered.lock().unwrap(),
            (0..spoken.len()).collect::<Vec<_>>()
        );
        audio::validate_audio(temp.path().join("audio.mp3"), 100).unwrap();
    }

    #[test]
    fn system_pcm_normalization_rejects_unsupported_sample_rates() {
        for rate in [1u32, 192000] {
            let mut wav = test_system_wav();
            wav[24..28].copy_from_slice(&rate.to_le_bytes());
            assert!(platform_tts::encode_wav(&wav).is_err());
        }
        let encoded = platform_tts::encode_wav(&test_system_wav()).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let artifact = temp.path().join("normalized.mp3");
        fs::write(&artifact, encoded).unwrap();
        assert_eq!(audio::probe_sample_rate(&artifact).unwrap(), 24000);
    }

    #[test]
    fn system_wav_with_extra_riff_chunks_is_encoded_and_truncation_rejected() {
        let mut wav = test_system_wav();
        let mut extra = b"JUNK".to_vec();
        extra.extend_from_slice(&4u32.to_le_bytes());
        extra.extend_from_slice(b"test");
        wav.splice(12..12, extra);
        let size = (wav.len() - 8) as u32;
        wav[4..8].copy_from_slice(&size.to_le_bytes());
        assert!(platform_tts::encode_wav(&wav).is_ok());
        wav.pop();
        assert!(platform_tts::encode_wav(&wav).is_err());
    }
    fn platform_test_book(path: &Path) {
        platform_test_book_with_text(path, "Uma frase para testar a voz offline.");
    }
    fn platform_test_book_with_text(path: &Path, text: &str) {
        use std::io::Write;
        let body = format!("<html><body><h1>Chapter</h1><p>{text}</p></body></html>");
        let mut archive = zip::ZipWriter::new(fs::File::create(path).unwrap());
        let options = zip::write::SimpleFileOptions::default();
        for (name, content) in [
            ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>"),
            ("content.opf", "<package xmlns:dc=\"x\"><metadata><dc:title>System speech</dc:title><dc:language>pt-BR</dc:language></metadata><manifest><item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"a\"/></spine></package>"),
            ("a.xhtml", body.as_str()),
        ] {
            archive.start_file(name, options).unwrap(); archive.write_all(content.as_bytes()).unwrap();
        }
        archive.finish().unwrap();
    }
    #[test]
    fn fallback_metadata_tracks_actual_role_when_primary_and_secondary_resolve_to_same_voice() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        for fail_primary in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let input = temp.path().join("book.epub");
            platform_test_book(&input);
            let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            ));
            let mut worker = ConversionWorker::new(config).unwrap();
            let attempts = Arc::new(AtomicUsize::new(0));
            let count = attempts.clone();
            worker.test_edge = Some(Arc::new(move |_| {
                if count.fetch_add(1, Ordering::AcqRel) == 0 && fail_primary {
                    Err(WorkerError::Edge(EdgeError::Timeout))
                } else {
                    Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
                }
            }));
            let mut request = preference_test_request();
            request.input = input;
            request.tts_preferences = Some(TtsPreferences {
                primary: TtsSelection {
                    engine: "edge".into(),
                    model_id: None,
                    voice: Some("pt-BR-FranciscaNeural".into()),
                },
                secondary: Some(TtsSelection {
                    engine: "edge".into(),
                    model_id: None,
                    voice: None,
                }),
                allow_online_fallback: true,
            });
            let first = worker.run(request.clone()).unwrap();
            assert_eq!(first.fallback_used, fail_primary);
            assert_eq!(first.used_selections.len(), 1);
            assert_eq!(
                first.used_selections[0].voice.as_deref(),
                Some("pt-BR-FranciscaNeural")
            );
            let calls = attempts.load(Ordering::Acquire);
            worker.jobs.delete(&request.job_id).unwrap();
            let cached = worker.resume(request.clone()).unwrap();
            assert_eq!(cached.fallback_used, fail_primary);
            assert_eq!(
                attempts.load(Ordering::Acquire),
                calls,
                "cache must preserve actual role without synthesis"
            );
            let audio = worker
                .config
                .paths
                .output_dir
                .join(&request.job_id)
                .join(&cached.chapters[0].filename);
            let receipt_path = chapter_audio_receipt_path(&audio);
            let mut legacy: serde_json::Value = cache::read_json(&receipt_path).unwrap();
            let key = legacy["request_key"].as_str().unwrap().to_owned();
            legacy.as_object_mut().unwrap().remove("fallback_used");
            cache::atomic_write_json(receipt_path, &legacy).unwrap();
            assert!(
                !chapter_audio_is_complete(&audio, &key),
                "receipts without actual fallback metadata must not be reused"
            );
        }
    }

    #[test]
    fn typed_failure_policy_survives_separate_single_chapter_requests() {
        use crate::tts_preferences::{SegmentPolicy, TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let mut state = SegmentPolicy::default();
        let spoken = Arc::new(Mutex::new(Vec::new()));
        for chapter in 0..3 {
            let input = temp.path().join(format!("chapter-{chapter}.epub"));
            platform_test_book_with_text(&input, &format!("Unique chapter {chapter}."));
            let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            ));
            let mut worker = ConversionWorker::new(config)
                .unwrap()
                .with_tts_policy_state(state)
                .with_platform_tts(Arc::new(TestSystem {
                    texts: spoken.clone(),
                }));
            worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Edge(EdgeError::Timeout))));
            let mut request = preference_test_request();
            request.input = input;
            request.job_id = format!("separate-chapter-{chapter}");
            request.tts_preferences = Some(TtsPreferences {
                primary: TtsSelection {
                    engine: "edge".into(),
                    model_id: None,
                    voice: None,
                },
                secondary: Some(TtsSelection {
                    engine: "system".into(),
                    model_id: None,
                    voice: None,
                }),
                allow_online_fallback: false,
            });
            let result = worker.run(request);
            if chapter == 2 {
                assert!(result
                    .unwrap_err()
                    .to_string()
                    .contains("three consecutive"));
                assert_eq!(spoken.lock().unwrap().len(), 2);
                return;
            }
            let manifest = result.unwrap();
            let encoded = serde_json::to_value(&manifest).unwrap();
            assert_eq!(
                encoded["ttsPolicyState"]["consecutive_failures"],
                chapter + 1
            );
            state = serde_json::from_value(encoded["ttsPolicyState"].clone()).unwrap();
        }
        panic!("the third separate request must stop");
    }

    #[test]
    fn platform_fallback_actual_worker_publishes_receipt_and_reports_cached_voice() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("book.epub");
        platform_test_book(&input);
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let output_dir = config.paths.output_dir.join("system-job");
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&events);
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }))
            .with_progress(Arc::new(move |event| sink.lock().unwrap().push(event)));
        worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Edge(EdgeError::Timeout))));
        let request = ConversionRequest {
            tts_preferences: None,
            models_root: None,
            input,
            job_id: "system-job".into(),
            engine: Some("edge".into()),
            voice: None,
            language: Some("pt-BR".into()),
            piper_model: None,
            piper_config: None,
            chapter_indices: None,
            no_parallel: true,
        };
        let manifest = worker.run(request.clone()).unwrap();
        assert_eq!(manifest.chapters.len(), 1);
        let audio = output_dir.join(&manifest.chapters[0].filename);
        assert!(platform_tts::validate_mp3(&fs::read(&audio).unwrap()).is_ok());
        let receipt: ChapterAudioReceipt =
            cache::read_json(chapter_audio_receipt_path(&audio)).unwrap();
        assert_eq!(receipt.provider.as_deref(), Some("system"));
        let calls = spoken.lock().unwrap().len();
        // A missing job record still permits recovery of durable chapter artifacts.
        worker.jobs.delete(&request.job_id).unwrap();
        worker.resume(request).unwrap();
        assert_eq!(spoken.lock().unwrap().len(), calls);
        assert!(events
            .lock()
            .unwrap()
            .iter()
            .any(|event| event.engine.as_deref() == Some("system")
                && event.message.contains("cached")));
    }
    #[test]
    fn invalid_system_wav_never_reaches_playback() {
        struct InvalidSystem;
        impl PlatformTts for InvalidSystem {
            fn synthesize_wav(
                &self,
                _: &str,
                _: &str,
                output: &Path,
                _: &(dyn Fn() -> bool + Sync),
            ) -> Result<(), String> {
                fs::write(output, b"invalid").map_err(|e| e.to_string())
            }
        }
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(InvalidSystem))
            .with_streaming_chunks(Arc::new(|_, _, _| {
                panic!("Invalid speech reached playback")
            }));
        assert!(matches!(
            worker.synthesize_platform_policy(
                "system",
                "Text",
                &temp.path().join("audio.mp3"),
                0,
                None,
                None,
                &std::sync::atomic::AtomicBool::new(false),
                &std::sync::atomic::AtomicBool::new(false),
                "job",
                1,
                0
            ),
            Err(WorkerError::PlatformTts(_))
        ));
    }
    #[test]
    fn edge_success_after_previous_native_notice_is_delivered() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let sticky = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let selected = Arc::clone(&sticky);
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }));
        let edge_bytes = platform_tts::encode_wav(&test_system_wav()).unwrap();
        worker.test_edge = Some(Arc::new(move |_| {
            selected.store(true, Ordering::Release);
            Ok(edge_bytes.clone())
        }));
        worker
            .synthesize_platform_policy(
                "edge",
                "Pending Edge segment",
                &temp.path().join("audio.mp3"),
                0,
                None,
                None,
                &std::sync::atomic::AtomicBool::new(false),
                &sticky,
                "job",
                1,
                0,
            )
            .unwrap();
        assert!(spoken.lock().unwrap().is_empty());
        assert_eq!(
            fs::read_to_string(temp.path().join("audio.provider")).unwrap(),
            "edge"
        );
    }
    #[test]
    fn cancelled_worker_does_not_wait_for_busy_native_speech_lock() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }));
        let _busy = worker.platform_gate.lock().unwrap();
        let output = temp.path().join("audio.mp3");
        std::thread::scope(|scope| {
            let waiting = scope.spawn(|| {
                worker.synthesize_platform_policy(
                    "system",
                    "Text",
                    &output,
                    0,
                    None,
                    None,
                    &std::sync::atomic::AtomicBool::new(false),
                    &std::sync::atomic::AtomicBool::new(false),
                    "job",
                    1,
                    0,
                )
            });
            std::thread::sleep(std::time::Duration::from_millis(50));
            worker.cancel();
            let started = std::time::Instant::now();
            assert!(matches!(
                waiting.join().unwrap(),
                Err(WorkerError::Cancelled)
            ));
            assert!(started.elapsed() < std::time::Duration::from_secs(1));
        });
        assert!(spoken.lock().unwrap().is_empty());
    }

    #[test]
    fn moved_playback_window_never_invokes_system() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let control = ConversionControl::new();
        let changed = control.clone();
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }))
            .with_control(control);
        worker.test_edge = Some(Arc::new(move |_| {
            changed.set_playback_window(1, 0);
            Err(WorkerError::Edge(EdgeError::Timeout))
        }));
        assert!(matches!(
            worker.synthesize_platform_policy(
                "edge",
                "Text",
                &temp.path().join("audio.mp3"),
                0,
                None,
                None,
                &std::sync::atomic::AtomicBool::new(false),
                &std::sync::atomic::AtomicBool::new(false),
                "job",
                1,
                0
            ),
            Err(WorkerError::PlaybackWindowChanged)
        ));
        assert!(spoken.lock().unwrap().is_empty());
    }

    #[test]
    fn platform_policy_has_a_distinct_cache_identity() {
        let edge =
            chapter_audio_request_key("book", "0", "Text", "edge", None, Some("pt-BR")).unwrap();
        let fallback =
            chapter_audio_request_key("book", "0", "Text", "edge+system-v2", None, Some("pt-BR"))
                .unwrap();
        assert_ne!(edge, fallback);
    }

    #[test]
    fn cancellation_never_invokes_system_fallback() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: Arc::clone(&spoken),
            }));
        worker.cancel();
        let error = worker
            .synthesize_platform_policy(
                "edge",
                "Hello",
                &temp.path().join("audio.mp3"),
                0,
                None,
                None,
                &std::sync::atomic::AtomicBool::new(false),
                &std::sync::atomic::AtomicBool::new(false),
                "job",
                1,
                0,
            )
            .unwrap_err();
        assert!(matches!(error, WorkerError::Cancelled));
        assert!(spoken.lock().unwrap().is_empty());
    }

    #[test]
    fn token_cancellation_is_durable_and_preserves_job_store_errors() {
        struct CancelDuringSpeech {
            cancel: CancellationToken,
            jobs: JobManager,
            durable_request: bool,
            remove_record: bool,
            calls: Arc<AtomicUsize>,
        }
        impl PlatformTts for CancelDuringSpeech {
            fn synthesize_wav(
                &self,
                _: &str,
                _: &str,
                _: &Path,
                _: &(dyn Fn() -> bool + Sync),
            ) -> Result<(), String> {
                self.calls.fetch_add(1, Ordering::Relaxed);
                if self.remove_record {
                    self.jobs.delete("cancelled-job").unwrap();
                } else if self.durable_request {
                    self.jobs.request_cancellation("cancelled-job").unwrap();
                }
                self.cancel.cancel();
                Err("fixture cancellation".into())
            }
        }
        for (durable_request, remove_record) in [(false, false), (true, false), (false, true)] {
            let temp = tempfile::tempdir().unwrap();
            let input = temp.path().join("book.epub");
            platform_test_book(&input);
            let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            ));
            let worker = ConversionWorker::new(config).unwrap();
            let jobs = worker.jobs.clone();
            let cancel = worker.cancel.clone();
            let calls = Arc::new(AtomicUsize::new(0));
            let worker = worker.with_platform_tts(Arc::new(CancelDuringSpeech {
                cancel,
                jobs: jobs.clone(),
                durable_request,
                remove_record,
                calls: Arc::clone(&calls),
            }));
            let result = worker.run(ConversionRequest {
                input,
                job_id: "cancelled-job".into(),
                tts_preferences: None,
                models_root: None,
                engine: Some("system".into()),
                voice: None,
                language: Some("pt-BR".into()),
                piper_model: None,
                piper_config: None,
                chapter_indices: None,
                no_parallel: true,
            });
            assert_eq!(calls.load(Ordering::Relaxed), 1);
            if remove_record {
                assert!(matches!(
                    result,
                    Err(WorkerError::Job(JobError::NotFound(_)))
                ));
            } else {
                assert!(matches!(result, Err(WorkerError::Cancelled)));
                assert_eq!(
                    jobs.load("cancelled-job").unwrap().state,
                    JobState::Cancelled
                );
            }
        }
    }

    #[test]
    fn positional_chapter_selector_from_ffi_matches_parsed_epub_position() {
        assert!(chapter_selection_matches("position:0", "1", 0));
        assert!(chapter_selection_matches("position:1", "2", 1));
        assert!(chapter_selection_matches("1", "1", 8));
        assert!(!chapter_selection_matches("position:0", "1", 1));
        assert!(!chapter_selection_matches("position:invalid", "1", 0));
    }

    #[test]
    fn stale_playback_chunk_is_rejected_without_publishing_chapter_audio() {
        let control = ConversionControl::new();
        control.set_playback_window(0, 1);
        let accepted_chunks = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let accepted = Arc::clone(&accepted_chunks);
        let sink: StreamingChunkSink = Arc::new(move |_, _, _| {
            accepted.fetch_add(1, Ordering::AcqRel);
            true
        });
        let stale = std::sync::atomic::AtomicBool::new(false);

        assert!(dispatch_playback_chunk(
            Some(&control),
            Some(&sink),
            0,
            0,
            b"current",
            &stale,
        ));
        control.set_playback_window(5, 1);
        assert!(!dispatch_playback_chunk(
            Some(&control),
            Some(&sink),
            0,
            1,
            b"stale",
            &stale,
        ));
        assert!(stale.load(Ordering::Acquire));
        assert_eq!(accepted_chunks.load(Ordering::Acquire), 1);

        let root = tempfile::tempdir().unwrap();
        let output = root.path().join("chapter.mp3");
        let result = ensure_chapter_audio(&output, "request-key", |_| {
            Err(WorkerError::PlaybackWindowChanged)
        });
        assert!(matches!(result, Err(WorkerError::PlaybackWindowChanged)));
        assert!(
            !output.exists(),
            "stale synthesis must not publish durable audio"
        );
    }

    #[test]
    fn malformed_chapter_cache_is_rebuilt_from_source() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        fs::write(&path, b"{broken JSON").unwrap();
        assert_eq!(
            cached_chapter_text(&path, "Original chapter.").unwrap(),
            "Original chapter."
        );
        assert_eq!(
            cache::read_json::<String>(&path).unwrap(),
            "Original chapter."
        );
    }

    #[test]
    fn matching_chapter_cache_is_reused_without_rewriting() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        let bytes = b"  \"Original chapter.\"\n";
        fs::write(&path, bytes).unwrap();
        assert_eq!(
            cached_chapter_text(&path, "Original chapter.").unwrap(),
            "Original chapter."
        );
        assert_eq!(fs::read(path).unwrap(), bytes);
    }

    #[test]
    fn missing_chapter_cache_is_created_and_write_failures_are_reported() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        assert_eq!(
            cached_chapter_text(&path, "Original chapter.").unwrap(),
            "Original chapter."
        );
        assert_eq!(
            cache::read_json::<String>(&path).unwrap(),
            "Original chapter."
        );
        let blocked = root.path().join("blocked.json");
        fs::create_dir(&blocked).unwrap();
        assert!(cached_chapter_text(&blocked, "Original chapter.").is_err());
    }

    #[test]
    fn same_length_cache_corruption_is_rebuilt_from_source() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        let expected = "The original chapter.";
        let corrupted = "x".repeat(expected.chars().count());
        cache::atomic_write_json(&path, &corrupted).unwrap();
        assert_eq!(cached_chapter_text(&path, expected).unwrap(), expected);
        assert_eq!(cache::read_json::<String>(&path).unwrap(), expected);
    }

    #[test]
    fn audio_request_key_changes_with_each_conversion_input() {
        let original = ("source", "1", "Text", "edge", Some("voice"), Some("en"));
        let key = |(source, chapter, text, engine, voice, language)| {
            chapter_audio_request_key(source, chapter, text, engine, voice, language).unwrap()
        };
        let expected = key(original);
        assert_eq!(key(original), expected);
        for changed in [
            ("other", "1", "Text", "edge", Some("voice"), Some("en")),
            ("source", "2", "Text", "edge", Some("voice"), Some("en")),
            ("source", "1", "Next", "edge", Some("voice"), Some("en")),
            ("source", "1", "Text", "piper", Some("voice"), Some("en")),
            ("source", "1", "Text", "edge", Some("other"), Some("en")),
            ("source", "1", "Text", "edge", Some("voice"), Some("fr")),
        ] {
            assert_ne!(key(changed), expected);
        }
    }

    #[test]
    fn legacy_output_manifest_keeps_unknown_source_count_without_changing_wire_shape() {
        let legacy = serde_json::json!({
            "jobId": "legacy-job", "title": "Book", "author": "Author",
            "chapters": [{"index": 1, "sourceIndex": 0, "title": "Chapter",
                          "filename": "chapter.mp3", "textChars": 40}],
            "archive": "book.zip", "cover": null
        });
        let manifest: OutputManifest = serde_json::from_value(legacy.clone()).unwrap();
        assert_eq!(manifest.source_chapters_total, None);
        assert_eq!(manifest.chapters.len(), 1);
        assert_eq!(serde_json::to_value(manifest).unwrap(), legacy);
    }

    #[test]
    fn explicit_source_count_round_trips_and_negative_count_is_rejected() {
        let mut value = serde_json::json!({
            "jobId": "selected-job", "title": "Book", "author": "Author",
            "chapters": [{"index": 1, "sourceIndex": 0, "title": "Chapter",
                          "filename": "chapter.mp3", "textChars": 40}],
            "sourceChaptersTotal": 2, "archive": "book.zip", "cover": null
        });
        let manifest: OutputManifest = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(manifest.source_chapters_total, Some(2));
        assert_eq!(manifest.chapters.len(), 1);
        assert_eq!(serde_json::to_value(manifest).unwrap(), value);
        value["sourceChaptersTotal"] = serde_json::json!(-1);
        assert!(serde_json::from_value::<OutputManifest>(value).is_err());
    }

    #[test]
    fn worker_reuses_proven_audio_and_publishes_the_matching_archive() {
        let root = tempfile::tempdir().unwrap();
        let paths = crate::paths::resolve_paths_from(
            std::collections::HashMap::<String, String>::new(),
            root.path().to_path_buf(),
        );
        let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
        let input = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../web/public/sample.epub");
        let source = fs::read(&input).unwrap();
        let book = epub::parse_epub(std::io::Cursor::new(&source)).unwrap();
        assert!(book.cover.is_none());
        assert_eq!(
            book.chapters.len(),
            2,
            "fixture must retain a larger source domain"
        );
        let chapter = &book.chapters[0];
        let output = worker.config.paths.output_dir.join("proven-existing-audio");
        let audio = output.join(format!("0001-{}.mp3", sanitize(&chapter.name)));
        let key = chapter_audio_request_key(
            &cache::sha256_bytes(&source),
            &chapter.index,
            &chapter.text,
            "piper",
            None,
            Some("en"),
        )
        .unwrap();
        ensure_chapter_audio(&audio, &key, |pending| {
            fs::write(pending, b"completed synthesis")?;
            Ok(())
        })
        .unwrap();
        let cached_text = worker
            .config
            .paths
            .cache_dir
            .join(cache::sha256_bytes(&source))
            .join(format!("{}.json", chapter.index.replace('.', "_")));
        cache::atomic_write_json(&cached_text, &"x".repeat(chapter.text.chars().count())).unwrap();

        let request = ConversionRequest {
            tts_preferences: None,
            models_root: None,
            input,
            job_id: "proven-existing-audio".into(),
            engine: Some("piper".into()),
            voice: None,
            language: Some("en".into()),
            piper_model: None,
            piper_config: None,
            chapter_indices: Some(vec!["0".into()]),
            no_parallel: true,
        };
        let manifest = worker.run(request.clone()).unwrap();
        assert_eq!(
            cache::read_json::<String>(&cached_text).unwrap(),
            chapter.text
        );
        assert_eq!(manifest.chapters.len(), 1);
        assert_eq!(manifest.chapters[0].source_index, 0);
        assert_eq!(manifest.source_chapters_total, Some(2));
        let persisted: OutputManifest = cache::read_json(output.join("manifest.json")).unwrap();
        assert_eq!(persisted.source_chapters_total, Some(2));
        assert_eq!(persisted.chapters.len(), 1);
        assert_eq!(persisted.chapters[0].source_index, 0);
        assert_eq!(
            worker.jobs.load("proven-existing-audio").unwrap().state,
            JobState::Completed
        );
        assert!(chapter_audio_is_complete(&audio, &key));
        let mut archive =
            zip::ZipArchive::new(fs::File::open(output.join(manifest.archive)).unwrap()).unwrap();
        let mut entry = archive.by_name(&manifest.chapters[0].filename).unwrap();
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(&mut entry, &mut bytes).unwrap();
        assert_eq!(bytes, b"completed synthesis");
        let changed_output = worker.config.paths.output_dir.join("changed-option-audio");
        fs::create_dir_all(&changed_output).unwrap();
        let changed_audio = changed_output.join(audio.file_name().unwrap());
        fs::copy(&audio, &changed_audio).unwrap();
        fs::copy(
            chapter_audio_receipt_path(&audio),
            chapter_audio_receipt_path(&changed_audio),
        )
        .unwrap();
        assert!(worker
            .run(ConversionRequest {
                tts_preferences: None,
                models_root: None,
                job_id: "changed-option-audio".into(),
                voice: Some("different-voice".into()),
                ..request
            })
            .is_err());
        assert_eq!(
            worker.jobs.load("changed-option-audio").unwrap().state,
            JobState::Failed
        );
        assert!(chapter_audio_is_complete(&changed_audio, &key));
        assert!(chapter_audio_is_complete(&audio, &key));
    }
    #[test]
    fn empty_existing_audio_is_not_a_completed_chapter() {
        let root = tempfile::tempdir().unwrap();
        let audio = root.path().join("chapter.mp3");
        fs::write(&audio, []).unwrap();
        ensure_chapter_audio(&audio, "request", |pending| {
            fs::write(pending, b"completed synthesis")?;
            Ok(())
        })
        .unwrap();
        assert_eq!(fs::read(audio).unwrap(), b"completed synthesis");
    }

    #[test]
    fn completed_audio_is_reused_only_for_the_same_request_and_content() {
        let root = tempfile::tempdir().unwrap();
        let audio = root.path().join("chapter.mp3");
        ensure_chapter_audio(&audio, "voice-one", |pending| {
            fs::write(pending, b"original")?;
            Ok(())
        })
        .unwrap();
        ensure_chapter_audio(&audio, "voice-one", |_| {
            panic!("valid audio must be reused")
        })
        .unwrap();
        assert!(!chapter_audio_is_complete(&audio, "voice-two"));
        // Equal-length corruption must not pass a size-only integrity check.
        fs::write(&audio, b"modified").unwrap();
        assert!(!chapter_audio_is_complete(&audio, "voice-one"));
        ensure_chapter_audio(&audio, "voice-one", |pending| {
            fs::write(pending, b"repaired")?;
            Ok(())
        })
        .unwrap();
        assert!(chapter_audio_is_complete(&audio, "voice-one"));
    }

    #[test]
    fn failed_audio_attempt_preserves_previous_audio_and_cleans_staging() {
        let root = tempfile::tempdir().unwrap();
        let audio = root.path().join("chapter.mp3");
        ensure_chapter_audio(&audio, "old-request", |pending| {
            fs::write(pending, b"original")?;
            Ok(())
        })
        .unwrap();
        let result = ensure_chapter_audio(&audio, "new-request", |pending| {
            fs::write(pending, b"partial")?;
            Err(WorkerError::Cancelled)
        });
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert_eq!(fs::read(&audio).unwrap(), b"original");
        assert!(chapter_audio_is_complete(&audio, "old-request"));
        assert!(!chapter_audio_is_complete(&audio, "new-request"));
        assert!(fs::read_dir(root.path())
            .unwrap()
            .all(|entry| !entry.unwrap().path().is_dir()));
    }

    #[test]
    fn chapter_receipt_publishes_actual_tts_usage_atomically() {
        use crate::tts_preferences::TtsSelection;
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("chapter.mp3");
        // Primary and automatic secondary can resolve to the same voice. The
        // role must come from synthesis, not be inferred from this selection.
        let selection = TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        };
        for fallback_used in [false, true] {
            let key = format!("same-voice-{fallback_used}");
            ensure_chapter_audio(&audio, &key, |pending| {
                fs::write(
                    pending,
                    platform_tts::encode_wav(&test_system_wav()).unwrap(),
                )?;
                cache::atomic_write_json(
                    pending.with_extension("tts-usage.json"),
                    &(vec![selection.clone()], fallback_used),
                )?;
                Ok(())
            })
            .unwrap();
            // Simulate interruption immediately after ensure returns: the outer
            // worker has not had a chance to rewrite or finalize metadata.
            let receipt: ChapterAudioReceipt =
                cache::read_json(chapter_audio_receipt_path(&audio)).unwrap();
            assert_eq!(receipt.used_selections, vec![selection.clone()]);
            assert_eq!(receipt.fallback_used, fallback_used);
            assert!(chapter_audio_is_complete(&audio, &key));
        }
    }

    #[test]
    fn empty_synthesis_does_not_publish_audio_or_a_receipt() {
        let root = tempfile::tempdir().unwrap();
        let audio = root.path().join("chapter.mp3");
        let result = ensure_chapter_audio(&audio, "request", |pending| {
            fs::write(pending, [])?;
            Ok(())
        });
        assert!(matches!(
            result,
            Err(WorkerError::Audio(audio::AudioError::Validation(_)))
        ));
        assert!(!audio.exists());
        assert!(!chapter_audio_receipt_path(&audio).exists());
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    }

    #[test]
    fn unmarked_audio_is_regenerated_and_cover_changes_refresh_integrity() {
        let root = tempfile::tempdir().unwrap();
        let audio = root.path().join("chapter.mp3");
        fs::write(&audio, b"unproven old artifact").unwrap();
        ensure_chapter_audio(&audio, "request", |pending| {
            fs::write(pending, b"complete")?;
            Ok(())
        })
        .unwrap();
        fs::write(&audio, b"complete with new cover tags").unwrap();
        assert!(!chapter_audio_is_complete(&audio, "request"));
        refresh_chapter_audio_receipt(&audio).unwrap();
        assert!(chapter_audio_is_complete(&audio, "request"));
        fs::write(chapter_audio_receipt_path(&audio), b"broken metadata").unwrap();
        assert!(!chapter_audio_is_complete(&audio, "request"));
    }

    #[test]
    fn worker_rejects_empty_audio_instead_of_completing_the_job() {
        let root = tempfile::tempdir().unwrap();
        let paths = crate::paths::resolve_paths_from(
            std::collections::HashMap::<String, String>::new(),
            root.path().to_path_buf(),
        );
        let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
        let input = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../web/public/sample.epub");
        let book = epub::parse_epub(std::io::Cursor::new(fs::read(&input).unwrap())).unwrap();
        assert!(book.cover.is_none());
        let output = worker.config.paths.output_dir.join("empty-existing-audio");
        fs::create_dir_all(&output).unwrap();
        let audio = output.join(format!("0001-{}.mp3", sanitize(&book.chapters[0].name)));
        fs::write(&audio, []).unwrap();
        let result = worker.run(ConversionRequest {
            tts_preferences: None,
            models_root: None,
            input,
            job_id: "empty-existing-audio".into(),
            engine: Some("piper".into()),
            voice: None,
            language: Some("en".into()),
            piper_model: None,
            piper_config: None,
            chapter_indices: Some(vec!["0".into()]),
            no_parallel: true,
        });
        assert!(result.is_err(), "an empty MP3 must not complete a job");
        assert_eq!(
            worker.jobs.load("empty-existing-audio").unwrap().state,
            JobState::Failed
        );
        assert!(!output.join("manifest.json").exists());
        assert_eq!(fs::metadata(audio).unwrap().len(), 0);
    }

    #[test]
    fn preference_edge_allows_first_audio_after_five_seconds() {
        let bytes = run_preference_edge_synthesis(
            async {
                tokio::time::sleep(std::time::Duration::from_millis(5_100)).await;
                Ok(vec![1, 2, 3])
            },
            &CancellationToken::default(),
            20,
        )
        .expect("Configured Edge must retain the reference client's connection/retry budget");
        assert_eq!(bytes, vec![1, 2, 3]);
    }

    #[test]
    fn preference_edge_keeps_cancellation_and_provider_error_identity() {
        let cancelled = CancellationToken::default();
        cancelled.cancel();
        assert!(matches!(
            run_preference_edge_synthesis::<Vec<u8>, _>(
                async { panic!("Cancelled jobs must not contact Edge") },
                &cancelled,
                20,
            ),
            Err(WorkerError::Cancelled)
        ));
        assert!(matches!(
            run_preference_edge_synthesis::<Vec<u8>, _>(
                async { Err(EdgeError::NoAudio) },
                &CancellationToken::default(),
                20,
            ),
            Err(WorkerError::Edge(EdgeError::NoAudio))
        ));
    }

    #[test]
    fn edge_synthesis_panic_remains_a_typed_worker_error() {
        let result = run_edge_synthesis::<Vec<u8>, _>(
            async { panic!("simulated synthesis panic") },
            &CancellationToken::default(),
            std::time::Duration::from_secs(1),
        );
        assert!(matches!(
            result,
            Err(WorkerError::Edge(EdgeError::Transport(message)))
                if message == "synthesis thread panicked"
        ));
    }

    #[test]
    fn edge_timeout_returns_before_the_pending_synthesis_finishes() {
        let started = std::time::Instant::now();
        let result = run_edge_synthesis::<Vec<u8>, _>(
            async {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                Ok(vec![1, 2, 3])
            },
            &CancellationToken::default(),
            std::time::Duration::from_millis(20),
        );
        assert!(matches!(
            result,
            Err(WorkerError::Edge(EdgeError::Transport(_)))
        ));
        assert!(
            started.elapsed() < std::time::Duration::from_millis(250),
            "timeout waited for synthesis: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn edge_timeout_does_not_wait_for_blocking_runtime_cleanup() {
        let started = std::time::Instant::now();
        let result = run_edge_synthesis(
            async {
                tokio::task::spawn_blocking(|| {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                });
                std::future::pending::<Result<Vec<u8>, EdgeError>>().await
            },
            &CancellationToken::default(),
            std::time::Duration::from_millis(20),
        );
        assert!(matches!(
            result,
            Err(WorkerError::Edge(EdgeError::Transport(_)))
        ));
        assert!(
            started.elapsed() < std::time::Duration::from_millis(250),
            "timeout waited for blocking cleanup: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn edge_cancellation_drops_active_synthesis_without_waiting_for_it() {
        struct DropSignal(Arc<std::sync::atomic::AtomicBool>);
        impl Drop for DropSignal {
            fn drop(&mut self) {
                self.0.store(true, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let dropped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let signal = DropSignal(dropped.clone());
        let cancel = CancellationToken::default();
        let started = std::time::Instant::now();
        let result = std::thread::scope(|scope| {
            let token = cancel.clone();
            scope.spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(20));
                token.cancel();
            });
            run_edge_synthesis(
                async move {
                    let _signal = signal;
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    Ok(vec![1])
                },
                &cancel,
                std::time::Duration::from_secs(1),
            )
        });
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert!(started.elapsed() < std::time::Duration::from_millis(250));
        assert!(dropped.load(std::sync::atomic::Ordering::SeqCst));
    }

    #[test]
    fn edge_cancelled_request_does_not_poll_synthesis() {
        let cancel = CancellationToken::default();
        cancel.cancel();
        let result = run_edge_synthesis::<Vec<u8>, _>(
            async { panic!("cancelled requests must not start synthesis") },
            &cancel,
            std::time::Duration::from_secs(1),
        );
        assert!(matches!(result, Err(WorkerError::Cancelled)));
    }

    #[test]
    fn edge_deadline_preserves_success_and_original_engine_error() {
        let cancel = CancellationToken::default();
        let timeout = std::time::Duration::from_secs(1);
        assert_eq!(
            run_edge_synthesis(async { Ok(vec![1, 2]) }, &cancel, timeout).unwrap(),
            vec![1, 2]
        );
        assert!(matches!(
            run_edge_synthesis::<Vec<u8>, _>(async { Err(EdgeError::NoAudio) }, &cancel, timeout),
            Err(WorkerError::Edge(EdgeError::NoAudio))
        ));
    }
}
