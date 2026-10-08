//! End-to-end conversion orchestration shared by the CLI and HTTP server.
use crate::{
    audio::{self, ChapterMetadata},
    cache,
    config::AppConfig,
    conversion_control::{ConversionControl, ConversionControlError},
    epub,
    jobs::{JobError, JobManager, JobRecord, JobState},
    piper::{self, CancellationToken, PiperConfig},
    tts::{EdgeError, Telemetry, TelemetryEvent},
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ConversionRequest {
    pub input: PathBuf,
    pub job_id: String,
    pub engine: Option<String>,
    pub voice: Option<String>,
    pub language: Option<String>,
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
    pub message: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct OutputManifest {
    pub job_id: String,
    pub title: String,
    pub author: String,
    pub chapters: Vec<ChapterMetadata>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_chapters_total: Option<usize>,
    pub archive: String,
    pub cover: Option<String>,
}

/// A complete, validated chapter that is safe to add to the playback queue.
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

/// Recoverable validated audio, independent of the terminal output manifest.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChapterJournal {
    schema_version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_chapters_total: Option<usize>,
    job_id: String,
    book_title: String,
    book_author: String,
    chapters_total: usize,
    chapters: Vec<ChapterCompletionEvent>,
}
#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("conversion control error: {0}")]
    Control(#[from] ConversionControlError),
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
    #[error("cancelled")]
    Cancelled,
    #[error("unsupported input: {0}")]
    Unsupported(String),
}
pub type ProgressSink = Arc<dyn Fn(ProgressEvent) + Send + Sync>;
pub type ChapterCompletionSink = Arc<dyn Fn(ChapterCompletionEvent) + Send + Sync>;

pub struct ConversionWorker {
    pub config: AppConfig,
    pub jobs: JobManager,
    pub cancel: CancellationToken,
    control: Option<ConversionControl>,
    pub progress: Option<ProgressSink>,
    pub chapter_completed: Option<ChapterCompletionSink>,
    pub adaptive: Arc<crate::adaptive::AdaptiveThroughputController>,
}
impl ConversionWorker {
    pub fn new(config: AppConfig) -> Result<Self, WorkerError> {
        let jobs = JobManager::new(&config.paths.jobs_dir)?;
        let adaptive = Arc::new(crate::adaptive::AdaptiveThroughputController::new(
            crate::adaptive::AdaptiveConfig {
                initial_chunk_chars: config.edge_chunk_chars,
                ..crate::adaptive::AdaptiveConfig::default()
            },
        ));
        Ok(Self {
            config,
            jobs,
            cancel: CancellationToken::default(),
            control: None,
            progress: None,
            chapter_completed: None,
            adaptive,
        })
    }
    pub fn with_progress(mut self, sink: ProgressSink) -> Self {
        self.progress = Some(sink);
        self
    }
    pub fn with_chapter_completed(mut self, sink: ChapterCompletionSink) -> Self {
        self.chapter_completed = Some(sink);
        self
    }
    pub fn with_cancellation(mut self, cancel: CancellationToken) -> Self {
        self.cancel = cancel;
        self
    }
    pub fn with_control(mut self, control: ConversionControl) -> Self {
        self.cancel = control.cancellation_token();
        self.control = Some(control);
        self
    }
    pub fn cancel(&self) {
        if let Some(control) = &self.control {
            control.cancel();
        } else {
            self.cancel.cancel();
        }
    }
    pub fn run(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        let metadata = serde_json::json!({"input":request.input,"engine":request.engine,"voice":request.voice,"language":request.language,"chapterIndices":request.chapter_indices,"recoveryJobId":self.control.as_ref().and_then(ConversionControl::recover_job)});
        let metadata = metadata.as_object().cloned().unwrap_or_default();
        match self.jobs.load(&request.job_id) {
            Ok(record) => {
                if ["input", "engine", "voice", "language"]
                    .iter()
                    .any(|key| record.metadata.get(*key) != metadata.get(*key))
                    || record
                        .metadata
                        .get("chapterIndices")
                        .is_some_and(|selection| Some(selection) != metadata.get("chapterIndices"))
                {
                    return Err(WorkerError::Piper(format!(
                        "job {} already exists with different conversion metadata",
                        request.job_id
                    )));
                }
                match record.state {
                    JobState::Queued => {
                        self.jobs.transition(&request.job_id, JobState::Running)?;
                    }
                    JobState::Running => {}
                    state => {
                        return Err(WorkerError::Piper(format!(
                            "job {} cannot resume from state {state:?}",
                            request.job_id
                        )));
                    }
                }
            }
            Err(JobError::NotFound(_)) => {
                self.jobs
                    .create(JobRecord::new(&request.job_id, metadata))?;
                self.jobs.transition(&request.job_id, JobState::Running)?;
            }
            Err(error) => return Err(error.into()),
        }
        let result = self.run_inner(&request);
        match &result {
            Ok(_) => {
                self.jobs.transition(&request.job_id, JobState::Completed)?;
                self.emit(ProgressEvent {
                    job_id: request.job_id.clone(),
                    state: "completed".into(),
                    chapter_index: None,
                    chapters_total: 0,
                    chapters_completed: 0,
                    percent: 100.0,
                    engine: request.engine.clone(),
                    message: "conversion completed".into(),
                });
            }
            Err(WorkerError::Cancelled) => {
                // Token cancellation also has to pass through the durable
                // cancelling state before the terminal event is observable.
                if self.jobs.load(&request.job_id)?.state != JobState::Cancelling {
                    self.jobs.request_cancellation(&request.job_id)?;
                }
                self.jobs.transition(&request.job_id, JobState::Cancelled)?;
                self.emit(ProgressEvent {
                    job_id: request.job_id.clone(),
                    state: "cancelled".into(),
                    chapter_index: None,
                    chapters_total: 0,
                    chapters_completed: 0,
                    percent: 0.0,
                    engine: request.engine.clone(),
                    message: "conversion cancelled".into(),
                });
            }
            Err(_) => {
                self.jobs.transition(&request.job_id, JobState::Failed)?;
                self.emit(ProgressEvent {
                    job_id: request.job_id.clone(),
                    state: "failed".into(),
                    chapter_index: None,
                    chapters_total: 0,
                    chapters_completed: 0,
                    percent: 0.0,
                    engine: request.engine.clone(),
                    message: "conversion failed".into(),
                });
            }
        }
        result
    }
    fn run_inner(&self, request: &ConversionRequest) -> Result<OutputManifest, WorkerError> {
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
        let cache_dir = self.config.paths.cache_dir.join(&book_key);
        let output_dir = self.config.paths.output_dir.join(&request.job_id);
        fs::create_dir_all(&cache_dir)?;
        fs::create_dir_all(&output_dir)?;
        let chapters: Vec<_> = book
            .chapters
            .iter()
            .enumerate()
            .filter(|(position, chapter)| {
                request
                    .chapter_indices
                    .as_ref()
                    .map(|wanted| {
                        wanted
                            .iter()
                            .any(|value| chapter_matches_selector(value, &chapter.index, *position))
                    })
                    .unwrap_or(true)
            })
            .map(|(source_position, chapter)| (source_position, chapter))
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
        self.emit(ProgressEvent {
            job_id: request.job_id.clone(),
            state: "running".into(),
            chapter_index: None,
            chapters_total: total,
            chapters_completed: 0,
            percent: 0.0,
            engine: request.engine.clone(),
            message: "conversion started".into(),
        });
        let detected_language = request
            .language
            .as_deref()
            .or(book.language.as_deref())
            .or_else(|| {
                book.chapters
                    .first()
                    .and_then(|chapter| detect_language(&chapter.text))
            });
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
        let parallelism = resolve_chapter_parallelism(
            request.no_parallel,
            configured,
            self.config.max_parallel,
            cap,
        );
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(parallelism)
            .build()
            .map_err(|error| WorkerError::Piper(error.to_string()))?;
        let results = Mutex::new(Vec::with_capacity(total));
        let journal_path = output_dir.join("chapters.json");
        let mut recovered_journal =
            recover_chapter_journal(&journal_path, &output_dir, &request.job_id, &book, total)?;
        if recovered_journal
            .source_sha256
            .as_ref()
            .is_some_and(|hash| hash != &book_key)
        {
            return Err(WorkerError::Piper(
                "chapter journal source hash mismatch".into(),
            ));
        }
        recovered_journal.source_sha256 = Some(book_key.clone());
        recovered_journal.source_chapters_total = Some(book.chapters.len());
        let completed_chapters = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let control = self.control.clone().unwrap_or_default();
        if let Some(source_job) = control.recover_job() {
            self.hydrate_successor(
                &source_job,
                request,
                &book,
                &book_key,
                &output_dir,
                &mut recovered_journal,
                &chapters
                    .iter()
                    .map(|(source, _)| *source)
                    .collect::<Vec<_>>(),
            )?;
            cache::atomic_write_json(&journal_path, &recovered_journal)?;
        }
        let chapter_journal = Mutex::new(recovered_journal);
        control.attach(
            &chapters
                .iter()
                .map(|(source, _)| *source)
                .collect::<Vec<_>>(),
        )?;
        pool.install(|| {
            (0..parallelism)
                .into_par_iter()
                .try_for_each(|_| -> Result<(), WorkerError> {
                    let outcome = (|| -> Result<(), WorkerError> {
                        loop {
                            if self.cancel.is_cancelled()
                                || self.jobs.is_cancellation_requested(&request.job_id)?
                            {
                                return Err(WorkerError::Cancelled);
                            }
                            let Some(source_position) = control.take()? else {
                                if self.cancel.is_cancelled() {
                                    return Err(WorkerError::Cancelled);
                                }
                                return Ok(());
                            };
                            let (position, (_, chapter)) = chapters
                                .iter()
                                .enumerate()
                                .find(|(_, (source, _))| *source == source_position)
                                .ok_or(ConversionControlError::UnavailableChapter(
                                    source_position,
                                ))?;
                            let chapter = *chapter;
                            let text_path =
                                cache_dir.join(format!("{}.json", chapter.index.replace('.', "_")));
                            let text = if text_path.is_file() {
                                cache::read_json::<String>(&text_path)?
                            } else {
                                cache::atomic_write_json(&text_path, &chapter.text)?;
                                chapter.text.clone()
                            };
                            if text.chars().count() != chapter.text.chars().count() {
                                return Err(WorkerError::Piper(format!(
                                    "cached chapter text mismatch for '{}'",
                                    chapter.name
                                )));
                            }
                            let stem = format!("{:04}-{}", position + 1, sanitize(&chapter.name));
                            let mp3 = chapter_output_path(
                                &output_dir,
                                &format!("{stem}.mp3"),
                                source_position,
                                &chapter_journal,
                            )?;
                            let language = detected_language;
                            let engine = select_engine(request.engine.as_deref(), &self.config);
                            self.emit(ProgressEvent {
                                job_id: request.job_id.clone(),
                                state: "running".into(),
                                chapter_index: Some(position),
                                chapters_total: total,
                                chapters_completed: completed_chapters
                                    .load(std::sync::atomic::Ordering::Acquire),
                                percent: completed_chapters
                                    .load(std::sync::atomic::Ordering::Acquire)
                                    as f64
                                    / total as f64
                                    * 100.0,
                                engine: Some(engine.clone()),
                                message: format!("converting chapter {}", position + 1),
                            });
                            let synthesis_started = std::time::Instant::now();
                            let synthesized = !mp3.is_file();
                            if synthesized {
                                eprintln!("synthesizing chapter {}/{}", position + 1, total);
                                self.synthesize_with_timeout(
                                    &engine,
                                    &text,
                                    &mp3,
                                    request.voice.as_deref(),
                                    request.language.as_deref().or(language),
                                    request.job_id.clone(),
                                    position,
                                    total,
                                    Arc::clone(&completed_chapters),
                                )?;
                            }
                            let chapter_name = chapter.name.clone();
                            let text_chars = text.chars().count();
                            let filename = mp3.file_name().unwrap().to_string_lossy().to_string();
                            let completed = completed_chapters
                                .fetch_add(1, std::sync::atomic::Ordering::AcqRel)
                                + 1;
                            let event = ChapterCompletionEvent {
                                job_id: request.job_id.clone(),
                                book_title: book.title.clone(),
                                book_author: book.author.clone(),
                                chapter_index: source_position,
                                chapters_total: total,
                                chapters_completed: completed,
                                chapter_title: chapter_name.clone(),
                                filename: filename.clone(),
                                audio_path: mp3.clone(),
                                text_chars,
                            };
                            persist_chapter_and_emit(
                                &journal_path,
                                &chapter_journal,
                                event,
                                self.chapter_completed.as_ref(),
                            )?;
                            let synthesis_elapsed = synthesis_started.elapsed().as_secs_f64();
                            let synthesis_rate = text_chars as f64 / synthesis_elapsed.max(0.001);
                            self.emit(ProgressEvent {
                                job_id: request.job_id.clone(),
                                state: "running".into(),
                                chapter_index: Some(position),
                                chapters_total: total,
                                chapters_completed: completed,
                                percent: completed as f64 / total as f64 * 100.0,
                                engine: Some(engine),
                                message: format!(
                                    "completed chapter {} in {:.1}s ({:.1} chars/s)",
                                    position + 1,
                                    synthesis_elapsed,
                                    synthesis_rate
                                ),
                            });
                            let name = mp3.file_name().unwrap().to_string_lossy().to_string();
                            results.lock().unwrap().push((
                                position,
                                mp3,
                                name.clone(),
                                ChapterMetadata {
                                    index: position + 1,
                                    source_index: source_position,
                                    title: chapter_name,
                                    filename: name,
                                    text_chars,
                                },
                                synthesized,
                            ));
                        }
                    })();
                    if outcome.is_err() {
                        // A failing worker must also release other workers
                        // waiting at a resource gate before rayon joins them.
                        control.cancel();
                    }
                    outcome
                })
        })?;
        if self.cancel.is_cancelled() || self.jobs.is_cancellation_requested(&request.job_id)? {
            return Err(WorkerError::Cancelled);
        }
        let mut results = results.into_inner().unwrap();
        results.sort_by_key(|item| item.0);
        let files: Vec<_> = results
            .iter()
            .map(|(_, path, name, _, _)| (path.clone(), name.clone()))
            .collect();
        let manifest: Vec<_> = results
            .iter()
            .map(|(_, _, _, metadata, _)| metadata.clone())
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
            for (_, path, _, _, synthesized) in &results {
                if *synthesized {
                    audio::embed_cover(path, &cover_path)?;
                }
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
        let result = OutputManifest {
            source_chapters_total: Some(book.chapters.len()),
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
        voice: Option<&str>,
        language: Option<&str>,
        telemetry: Option<Telemetry>,
    ) -> Result<(), WorkerError> {
        if engine == "edge" {
            let voice = voice.unwrap_or_else(|| default_edge_voice(language));
            let rt = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()?;
            let result = rt.block_on(cancellable_edge_synthesis(
                &self.cancel,
                crate::tts::synthesize_with_reference_client(
                    text,
                    voice,
                    Arc::clone(&self.adaptive),
                    telemetry,
                ),
            ));
            rt.shutdown_timeout(std::time::Duration::from_secs(1));
            match result {
                Ok(bytes) => {
                    if self.cancel.is_cancelled() {
                        return Err(WorkerError::Cancelled);
                    }
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
        self.synthesize_with_piper(text, out)
    }

    fn synthesize_with_piper(&self, text: &str, out: &Path) -> Result<(), WorkerError> {
        if cfg!(target_os = "android") {
            return Err(WorkerError::Piper(
                "Piper is disabled on Android; Edge TTS is required".into(),
            ));
        }
        let model = std::env::var_os("PIPER_MODEL")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
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
        let config = model.with_extension("onnx.json");
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
        voice: Option<&str>,
        language: Option<&str>,
        job_id: String,
        chapter_index: usize,
        chapters_total: usize,
        completed_chapters: Arc<std::sync::atomic::AtomicUsize>,
    ) -> Result<(), WorkerError> {
        let default_timeout = if engine == "edge" {
            let synthesis_budget = crate::tts::reference_synthesis_timeout_for_text(text.len())
                .as_secs()
                .saturating_add(10);
            synthesis_budget
        } else if cfg!(target_os = "android") {
            300
        } else {
            180
        };
        let timeout_secs = std::env::var("RUST_CHAPTER_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(default_timeout);
        let cancel = self.cancel.clone();
        let engine_owned = engine.to_owned();
        let text_owned = text.to_owned();
        static SYNTHESIS_ATTEMPT_ID: std::sync::atomic::AtomicU64 =
            std::sync::atomic::AtomicU64::new(0);
        let attempt_id = SYNTHESIS_ATTEMPT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut temporary_output = out.as_os_str().to_os_string();
        temporary_output.push(format!(".{}.{}.partial", std::process::id(), attempt_id));
        let temporary_output = PathBuf::from(temporary_output);
        let out_owned = temporary_output.clone();
        let voice_owned = voice.map(str::to_owned);
        let language_owned = language.map(str::to_owned);
        let synthesis_config = self.config.clone();
        let adaptive = Arc::clone(&self.adaptive);
        let progress = self.progress.clone();
        let telemetry_cancel = self.cancel.clone();
        let telemetry: Option<Telemetry> = progress.as_ref().map(|sink| {
            let sink = Arc::clone(sink);
            let job_id = job_id.clone();
            let completed_chapters = Arc::clone(&completed_chapters);
            Arc::new(move |event| {
                if telemetry_cancel.is_cancelled() {
                    return;
                }
                let TelemetryEvent::ChunkMetrics {
                    provider,
                    chunk_index: chunk_number,
                    total_chunks,
                    chars,
                    elapsed_ms,
                    chars_per_second,
                    retries,
                    chunk_limit,
                    max_in_flight,
                    cooldown_ms,
                    result,
                } = event
                else {
                    return;
                };
                let completed = completed_chapters
                    .load(std::sync::atomic::Ordering::Acquire);
                sink(ProgressEvent {
                    job_id: job_id.clone(),
                    state: "running".into(),
                    chapter_index: Some(chapter_index),
                    chapters_total,
                    chapters_completed: completed,
                    percent: completed as f64 / chapters_total.max(1) as f64 * 100.0,
                    engine: Some(provider.clone()),
                    message: format!(
                        "tts chunk={chunk_number}/{total_chunks} chars={chars} elapsed_ms={elapsed_ms} chars_per_second={chars_per_second:.1} retries={retries} chunk_limit={chunk_limit} max_in_flight={max_in_flight} cooldown_ms={cooldown_ms} result={result}"
                    ),
                });
            }) as Telemetry
        });
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let spawn = std::thread::Builder::new()
            .name("converter-chapter-synthesis".into())
            .stack_size(8 * 1024 * 1024)
            .spawn(move || {
                let worker = Self::new(synthesis_config);
                let result = worker.map_or_else(Err, |mut worker| {
                    worker.cancel = cancel.clone();
                    worker.adaptive = adaptive;
                    worker.progress = progress;
                    worker.synthesize(
                        &engine_owned,
                        &text_owned,
                        &out_owned,
                        voice_owned.as_deref(),
                        language_owned.as_deref(),
                        telemetry,
                    )
                });
                if result.is_err() || cancel.is_cancelled() {
                    let _ = fs::remove_file(&out_owned);
                }
                if sender.send(result).is_err() {
                    let _ = fs::remove_file(&out_owned);
                }
            });
        let thread = spawn.map_err(|error| {
            WorkerError::Piper(format!("failed to start synthesis thread: {error}"))
        })?;
        self.await_synthesis_attempt(
            engine,
            receiver,
            thread,
            &temporary_output,
            out,
            std::time::Duration::from_secs(timeout_secs),
        )
    }

    fn hydrate_successor(
        &self,
        source_job: &str,
        request: &ConversionRequest,
        book: &epub::Book,
        source_hash: &str,
        output_dir: &Path,
        journal: &mut ChapterJournal,
        selected: &[usize],
    ) -> Result<(), WorkerError> {
        if source_job == request.job_id {
            return Err(WorkerError::Piper(
                "recovery requires a distinct successor job ID".into(),
            ));
        }
        let record = self.jobs.load(source_job)?;
        let current = serde_json::json!({"engine":request.engine,"voice":request.voice,"language":request.language});
        if ["engine", "voice", "language"]
            .iter()
            .any(|key| record.metadata.get(*key) != current.get(*key))
        {
            return Err(WorkerError::Piper(
                "recovery provider configuration mismatch".into(),
            ));
        }
        let source_dir = self.config.paths.output_dir.join(source_job);
        let canonical_source = source_dir.canonicalize()?;
        if canonical_source.parent() != Some(self.config.paths.output_dir.canonicalize()?.as_path())
        {
            return Err(WorkerError::Piper(
                "recovery output escapes conversion root".into(),
            ));
        }
        let source_journal_path = source_dir.join("chapters.json");
        let mut source_journal = recover_chapter_journal(
            &source_journal_path,
            &source_dir,
            source_job,
            book,
            selected.len(),
        )?;
        let verified_hash = match source_journal.source_sha256.as_deref() {
            Some(hash) => hash.to_owned(),
            None => {
                let input = record
                    .metadata
                    .get("input")
                    .and_then(|value| value.as_str())
                    .ok_or_else(|| {
                        WorkerError::Piper("recovery source identity is unavailable".into())
                    })?;
                cache::sha256_file(input)?
            }
        };
        if verified_hash != source_hash {
            return Err(WorkerError::Piper("recovery source hash mismatch".into()));
        }
        let manifest_path = source_dir.join("manifest.json");
        if manifest_path.exists() {
            let manifest: OutputManifest = cache::read_json(&manifest_path)?;
            if manifest.job_id != source_job
                || manifest.title != book.title
                || manifest.author != book.author
            {
                return Err(WorkerError::Piper(
                    "recovery manifest identity mismatch".into(),
                ));
            }
            for chapter in manifest.chapters {
                if source_journal
                    .chapters
                    .iter()
                    .any(|event| event.chapter_index == chapter.source_index)
                {
                    continue;
                }
                let event = ChapterCompletionEvent {
                    job_id: source_job.to_owned(),
                    book_title: book.title.clone(),
                    book_author: book.author.clone(),
                    chapter_index: chapter.source_index,
                    chapters_total: source_journal.chapters_total,
                    chapters_completed: 0,
                    chapter_title: chapter.title,
                    audio_path: source_dir.join(&chapter.filename),
                    filename: chapter.filename,
                    text_chars: chapter.text_chars,
                };
                if recovery_audio_valid(&event, &canonical_source, source_job, book) {
                    source_journal.chapters.push(event);
                }
            }
        }
        let canonical_destination = output_dir.canonicalize()?;
        for source_event in source_journal
            .chapters
            .into_iter()
            .filter(|event| selected.contains(&event.chapter_index))
        {
            if journal
                .chapters
                .iter()
                .any(|event| event.chapter_index == source_event.chapter_index)
            {
                continue;
            }
            let filename = format!(
                "source-{:04}-{}.mp3",
                source_event.chapter_index,
                sanitize(&source_event.chapter_title)
            );
            let destination = output_dir.join(&filename);
            if destination.exists() {
                if destination.canonicalize()? != canonical_destination.join(&filename) {
                    return Err(WorkerError::Piper(
                        "recovery destination escapes successor output".into(),
                    ));
                }
                if cache::sha256_file(&destination)?
                    != cache::sha256_file(&source_event.audio_path)?
                {
                    return Err(WorkerError::Piper(
                        "recovery destination contains different audio".into(),
                    ));
                }
            } else {
                fs::hard_link(&source_event.audio_path, &destination)?;
            }
            audio::validate_audio(&destination, 100)?;
            journal.chapters.push(ChapterCompletionEvent {
                job_id: request.job_id.clone(),
                filename,
                audio_path: destination,
                chapters_total: selected.len(),
                chapters_completed: journal.chapters.len() + 1,
                ..source_event
            });
        }
        journal.chapters_total = selected.len();
        journal.chapters.sort_by_key(|event| event.chapter_index);
        Ok(())
    }

    fn await_synthesis_attempt(
        &self,
        engine: &str,
        receiver: std::sync::mpsc::Receiver<Result<(), WorkerError>>,
        thread: std::thread::JoinHandle<()>,
        temporary_output: &Path,
        out: &Path,
        timeout: std::time::Duration,
    ) -> Result<(), WorkerError> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let cancelled = self.cancel.is_cancelled();
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if cancelled || remaining.is_zero() {
                self.cancel();
                drop(receiver);
                // Edge cancellation drops its async request and owns callback
                // teardown. Native synchronous inference retains its existing
                // cooperative boundary; do not block cancellation on its join.
                if engine == "edge" {
                    let _ = thread.join();
                }
                let _ = fs::remove_file(temporary_output);
                return Err(if cancelled {
                    WorkerError::Cancelled
                } else if engine == "edge" {
                    WorkerError::Edge(EdgeError::Transport("chapter synthesis timed out".into()))
                } else {
                    WorkerError::Piper("chapter synthesis timed out".into())
                });
            }
            match receiver.recv_timeout(remaining.min(std::time::Duration::from_millis(25))) {
                Ok(result) => {
                    let joined = thread.join();
                    if self.cancel.is_cancelled() {
                        let _ = fs::remove_file(temporary_output);
                        return Err(WorkerError::Cancelled);
                    }
                    if joined.is_err() {
                        let _ = fs::remove_file(temporary_output);
                        return Err(WorkerError::Piper("synthesis thread panicked".into()));
                    }
                    if let Err(error) = result {
                        let _ = fs::remove_file(temporary_output);
                        return Err(error);
                    }
                    return fs::rename(temporary_output, out).map_err(WorkerError::Io);
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    let _ = thread.join();
                    let _ = fs::remove_file(temporary_output);
                    return Err(WorkerError::Piper(
                        "synthesis thread exited without a result".into(),
                    ));
                }
            }
        }
    }
    #[allow(dead_code)]
    fn emit(&self, event: ProgressEvent) {
        if let Some(sink) = &self.progress {
            sink(event)
        }
    }
}

async fn cancellable_edge_synthesis<F>(
    cancel: &CancellationToken,
    synthesis: F,
) -> Result<Vec<u8>, WorkerError>
where
    F: std::future::Future<Output = Result<Vec<u8>, EdgeError>>,
{
    tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(WorkerError::Cancelled),
        result = synthesis => result.map_err(WorkerError::Edge),
    }
}

fn persist_chapter_and_emit(
    journal_path: &Path,
    journal: &Mutex<ChapterJournal>,
    event: ChapterCompletionEvent,
    sink: Option<&ChapterCompletionSink>,
) -> Result<(), WorkerError> {
    audio::validate_audio(&event.audio_path, 100)?;
    {
        // Hold the lock through the atomic replacement so parallel chapter
        // completion cannot replace a newer journal with an older snapshot.
        let mut journal = journal
            .lock()
            .map_err(|_| WorkerError::Piper("chapter journal lock poisoned".into()))?;
        journal
            .chapters
            .retain(|chapter| chapter.chapter_index != event.chapter_index);
        journal.chapters.push(event.clone());
        journal
            .chapters
            .sort_by_key(|chapter| chapter.chapter_index);
        cache::atomic_write_json(journal_path, &*journal)?;
    }
    if let Some(sink) = sink {
        sink(event);
    }
    Ok(())
}

fn recover_chapter_journal(
    journal_path: &Path,
    output_dir: &Path,
    job_id: &str,
    book: &epub::Book,
    chapters_total: usize,
) -> Result<ChapterJournal, WorkerError> {
    if !journal_path.exists() {
        return Ok(ChapterJournal {
            schema_version: 1,
            source_sha256: None,
            source_chapters_total: Some(book.chapters.len()),
            job_id: job_id.to_owned(),
            book_title: book.title.clone(),
            book_author: book.author.clone(),
            chapters_total,
            chapters: Vec::new(),
        });
    }
    let mut journal: ChapterJournal = cache::read_json(journal_path)?;
    if journal.schema_version != 1
        || journal.job_id != job_id
        || journal.book_title != book.title
        || journal.book_author != book.author
    {
        return Err(WorkerError::Piper(
            "incompatible chapter journal identity".into(),
        ));
    }
    let canonical_output = output_dir.canonicalize()?;
    journal
        .chapters
        .retain(|event| recovery_audio_valid(event, &canonical_output, job_id, book));
    journal.chapters.sort_by_key(|event| event.chapter_index);
    journal.chapters.dedup_by_key(|event| event.chapter_index);
    journal.chapters_total = journal.chapters_total.max(chapters_total);
    Ok(journal)
}

fn recovery_audio_valid(
    event: &ChapterCompletionEvent,
    canonical_output: &Path,
    job_id: &str,
    book: &epub::Book,
) -> bool {
    let filename = Path::new(&event.filename);
    let Some(chapter) = book.chapters.get(event.chapter_index) else {
        return false;
    };
    if filename.components().count() != 1
        || !matches!(
            filename.components().next(),
            Some(std::path::Component::Normal(_))
        )
        || event.job_id != job_id
        || event.book_title != book.title
        || event.book_author != book.author
        || event.chapter_title != chapter.name
        || event.text_chars != chapter.text.chars().count()
    {
        return false;
    }
    let expected = canonical_output.join(filename);
    let Ok(actual) = event.audio_path.canonicalize() else {
        return false;
    };
    actual == expected && audio::validate_audio(&actual, 100).is_ok()
}

fn chapter_output_path(
    output_dir: &Path,
    filename: &str,
    source_index: usize,
    journal: &Mutex<ChapterJournal>,
) -> Result<PathBuf, WorkerError> {
    let journal = journal
        .lock()
        .map_err(|_| WorkerError::Piper("chapter journal lock poisoned".into()))?;
    if let Some(existing) = journal
        .chapters
        .iter()
        .find(|chapter| chapter.chapter_index == source_index)
    {
        return Ok(existing.audio_path.clone());
    }
    if journal
        .chapters
        .iter()
        .any(|chapter| chapter.filename == filename)
    {
        return Ok(output_dir.join(format!("source-{source_index:04}-{filename}")));
    }
    Ok(output_dir.join(filename))
}

fn chapter_matches_selector(selector: &str, toc_index: &str, position: usize) -> bool {
    if let Some(value) = selector.strip_prefix("position:") {
        return value.parse::<usize>().ok() == Some(position);
    }
    if let Some(value) = selector.strip_prefix("toc:") {
        return value == toc_index;
    }
    selector == toc_index || selector.parse::<usize>().ok() == Some(position)
}

fn resolve_chapter_parallelism(
    no_parallel: bool,
    configured: usize,
    max_parallel: usize,
    cap: usize,
) -> usize {
    if no_parallel {
        return 1;
    }
    configured.min(max_parallel).min(cap).max(1)
}

#[cfg(test)]
mod streaming_tests {
    use super::*;
    use std::io::Write;
    use zip::{write::SimpleFileOptions, ZipWriter};

    #[tokio::test]
    async fn edge_cancellation_before_registration_rejects_ready_audio() {
        let cancel = CancellationToken::default();
        cancel.cancel();
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            cancellable_edge_synthesis(&cancel, async { Ok(vec![1u8]) }),
        )
        .await
        .unwrap();
        assert!(matches!(result, Err(WorkerError::Cancelled)));
    }

    #[tokio::test]
    async fn edge_cancellation_drops_stalled_request_without_publishing_audio() {
        struct RequestLifetime(Arc<std::sync::atomic::AtomicBool>);
        impl Drop for RequestLifetime {
            fn drop(&mut self) {
                self.0.store(true, std::sync::atomic::Ordering::Release);
            }
        }
        let cancel = CancellationToken::default();
        let dropped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let publication = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let observed = Arc::clone(&dropped);
        let published = Arc::clone(&publication);
        let request = async move {
            let _lifetime = RequestLifetime(observed);
            ready_tx.send(()).unwrap();
            std::future::pending::<()>().await;
            published.store(true, std::sync::atomic::Ordering::Release);
            Ok(vec![1u8])
        };
        let cancel_clone = cancel.clone();
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), async {
            tokio::join!(cancellable_edge_synthesis(&cancel, request), async {
                ready_rx.await.unwrap();
                cancel_clone.cancel();
            },)
            .0
        })
        .await
        .unwrap();
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert!(dropped.load(std::sync::atomic::Ordering::Acquire));
        assert!(!publication.load(std::sync::atomic::Ordering::Acquire));
    }

    #[test]
    fn cancellation_unwinds_inflight_edge_attempt_before_return_and_never_renames_partial() {
        let temp = tempfile::tempdir().unwrap();
        let paths = crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        );
        let control = ConversionControl::new();
        let worker = ConversionWorker::new(AppConfig::from_paths(paths))
            .unwrap()
            .with_control(control.clone());
        let partial = temp.path().join("inflight.partial");
        let final_audio = temp.path().join("inflight.mp3");
        fs::write(&partial, b"partial provider bytes").unwrap();
        let producer_path = partial.clone();
        let cancel = control.cancellation_token();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
        let unwound = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let observed = Arc::clone(&unwound);
        let producer = std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_time()
                .build()
                .unwrap();
            let result = runtime.block_on(cancellable_edge_synthesis(&cancel, async {
                ready_tx.send(()).unwrap();
                std::future::pending::<Result<Vec<u8>, EdgeError>>().await
            }));
            observed.store(true, std::sync::atomic::Ordering::Release);
            let result =
                result.and_then(|bytes| fs::write(&producer_path, bytes).map_err(WorkerError::Io));
            if result.is_err() {
                let _ = fs::remove_file(&producer_path);
            }
            let _ = result_tx.send(result);
        });
        ready_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .unwrap();
        let started = std::time::Instant::now();
        control.cancel();
        let result = worker.await_synthesis_attempt(
            "edge",
            result_rx,
            producer,
            &partial,
            &final_audio,
            std::time::Duration::from_secs(180),
        );
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
        assert!(unwound.load(std::sync::atomic::Ordering::Acquire));
        assert!(!partial.exists());
        assert!(!final_audio.exists());
    }

    fn test_journal(chapters_total: usize) -> Mutex<ChapterJournal> {
        Mutex::new(ChapterJournal {
            schema_version: 1,
            source_sha256: None,
            source_chapters_total: None,
            job_id: "stream-test".into(),
            book_title: "Fixture".into(),
            book_author: "Author".into(),
            chapters_total,
            chapters: Vec::new(),
        })
    }

    fn write_test_wav(path: &Path) {
        let sample_rate = 8_000u32;
        let samples = vec![0u8; sample_rate as usize * 2];
        let mut bytes = Vec::with_capacity(44 + samples.len());
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36u32 + samples.len() as u32).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&sample_rate.to_le_bytes());
        bytes.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(samples.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&samples);
        fs::write(path, bytes).unwrap();
    }

    fn event(index: usize, path: PathBuf) -> ChapterCompletionEvent {
        ChapterCompletionEvent {
            job_id: "stream-test".into(),
            book_title: "Fixture".into(),
            book_author: "Author".into(),
            chapter_index: index,
            chapters_total: 2,
            chapters_completed: index + 1,
            chapter_title: format!("Chapter {index}"),
            filename: format!("chapter-{index}.mp3"),
            audio_path: path,
            text_chars: 100,
        }
    }

    fn write_test_epub(path: &Path) {
        write_test_epub_chapters(path, 1);
    }

    fn write_test_epub_chapters(path: &Path, count: usize) {
        write_test_epub_chapters_with_titles(path, count, false);
    }

    fn write_test_epub_chapters_with_titles(path: &Path, count: usize, repeated_title: bool) {
        let file = fs::File::create(path).unwrap();
        let mut zip = ZipWriter::new(file);
        let stored =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        let options = SimpleFileOptions::default();
        zip.start_file("mimetype", stored).unwrap();
        zip.write_all(b"application/epub+zip").unwrap();
        zip.start_file("META-INF/container.xml", options).unwrap();
        zip.write_all(br#"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#).unwrap();
        zip.start_file("OPS/package.opf", options).unwrap();
        let manifest = (0..count)
            .map(|index| format!(r#"<item id="chapter{index}" href="chapter{index}.xhtml" media-type="application/xhtml+xml"/>"#))
            .collect::<String>();
        let spine = (0..count)
            .map(|index| format!(r#"<itemref idref="chapter{index}"/>"#))
            .collect::<String>();
        let package = format!(
            r#"<package xmlns="http://www.idpf.org/2007/opf"><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Resume fixture</dc:title><dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Test</dc:creator></metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>"#
        );
        zip.write_all(package.as_bytes()).unwrap();
        for index in 0..count {
            zip.start_file(format!("OPS/chapter{index}.xhtml"), options)
                .unwrap();
            let title = if repeated_title {
                "Same Title".into()
            } else {
                format!("Chapter {index}")
            };
            let content = format!(
                r#"<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>{title}</h1><p>Existing validated audio {index} can be resumed.</p></body></html>"#
            );
            zip.write_all(content.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
    }

    #[test]
    fn resumes_running_job_from_existing_audio_without_rewriting_it() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let input = root.join("resume.epub");
        write_test_epub(&input);
        let paths = crate::paths::Paths {
            project_root: root.to_path_buf(),
            persistent_root: root.to_path_buf(),
            cache_dir: root.join(".cache"),
            output_dir: root.join("outputs"),
            jobs_dir: root.join(".jobs"),
            uploads_dir: root.join(".uploads"),
            job_inputs_dir: root.join(".job_inputs"),
            source_backups_dir: root.join(".source_backups"),
            logs_dir: root.join(".logs"),
            telemetry_dir: root.join(".telemetry"),
            models_dir: root.join("models"),
            piper_models_dir: root.join("models/piper"),
        };
        let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
        let job_id = "resume-existing-job";
        let input_text = input.to_string_lossy().into_owned();
        let metadata = serde_json::json!({
            "input": input_text,
            "engine": "edge",
            "voice": null,
            "language": null
        })
        .as_object()
        .unwrap()
        .clone();
        worker
            .jobs
            .create(JobRecord::new(job_id, metadata))
            .unwrap();
        worker.jobs.transition(job_id, JobState::Running).unwrap();

        let output_directory = root.join("outputs").join(job_id);
        fs::create_dir_all(&output_directory).unwrap();
        let book = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
        let existing_audio =
            output_directory.join(format!("0001-{}.mp3", sanitize(&book.chapters[0].name)));
        write_test_wav(&existing_audio);
        let original_audio = fs::read(&existing_audio).unwrap();
        let observed_jobs = worker.jobs.clone();
        let observed_output = output_directory.clone();
        let worker = worker.with_progress(Arc::new(move |event| {
            if event.state == "completed" {
                assert_eq!(
                    observed_jobs.load(&event.job_id).unwrap().state,
                    JobState::Completed,
                    "completion must already be durable when published"
                );
                assert!(observed_output.join("manifest.json").is_file());
            }
        }));

        let result = worker.run(ConversionRequest {
            input,
            job_id: job_id.into(),
            engine: Some("edge".into()),
            voice: None,
            language: None,
            chapter_indices: None,
            no_parallel: true,
        });

        assert!(result.is_ok(), "active jobs should resume: {result:?}");
        assert_eq!(worker.jobs.load(job_id).unwrap().state, JobState::Completed);
        assert_eq!(fs::read(&existing_audio).unwrap(), original_audio);
        assert!(output_directory.join("manifest.json").is_file());
    }

    #[test]
    fn token_cancellation_is_durable_before_callback_and_not_recovered_as_active() {
        let temp = tempfile::tempdir().unwrap();
        let paths = crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        );
        let control = ConversionControl::new();
        let worker = ConversionWorker::new(AppConfig::from_paths(paths))
            .unwrap()
            .with_control(control.clone());
        let jobs = worker.jobs.clone();
        let observed_jobs = jobs.clone();
        let worker = worker.with_progress(Arc::new(move |event| {
            if event.state == "cancelled" {
                assert_eq!(
                    observed_jobs.load(&event.job_id).unwrap().state,
                    JobState::Cancelled
                );
            }
        }));
        let input = temp.path().join("cancel.epub");
        write_test_epub(&input);
        control.cancel();
        let result = worker.run(ConversionRequest {
            input,
            job_id: "cancel-token".into(),
            engine: Some("edge".into()),
            voice: None,
            language: None,
            chapter_indices: None,
            no_parallel: true,
        });
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert_eq!(
            jobs.load("cancel-token").unwrap().state,
            JobState::Cancelled
        );
        assert!(jobs.recover_active().unwrap().is_empty());
    }

    #[test]
    fn controlled_conversion_changes_priority_between_chapter_callbacks() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("controlled.epub");
        write_test_epub_chapters(&input, 4);
        let paths = crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        );
        let output = paths.output_dir.join("controlled-job");
        fs::create_dir_all(&output).unwrap();
        let book = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
        for (position, chapter) in book.chapters.iter().enumerate() {
            write_test_wav(&output.join(format!(
                "{:04}-{}.mp3",
                position + 1,
                sanitize(&chapter.name)
            )));
        }
        let control = ConversionControl::new();
        control.prioritize(2).unwrap();
        let observed = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&observed);
        let callback_control = control.clone();
        let worker = ConversionWorker::new(AppConfig::from_paths(paths))
            .unwrap()
            .with_control(control)
            .with_chapter_completed(Arc::new(move |event| {
                captured.lock().unwrap().push(event.chapter_index);
                if event.chapter_index == 2 {
                    assert!(callback_control.prioritize(99).is_err());
                    callback_control.prioritize(0).unwrap();
                }
            }));
        let result = worker.run(ConversionRequest {
            input,
            job_id: "controlled-job".into(),
            engine: Some("edge".into()),
            voice: None,
            language: None,
            chapter_indices: None,
            no_parallel: true,
        });
        assert!(
            result.is_ok(),
            "controlled cached audio should finish: {result:?}"
        );
        assert_eq!(*observed.lock().unwrap(), vec![2, 0, 1, 3]);
        assert_eq!(
            result
                .unwrap()
                .chapters
                .iter()
                .map(|chapter| chapter.source_index)
                .collect::<Vec<_>>(),
            vec![0, 1, 2, 3],
            "terminal manifest retains source order independently of synthesis priority"
        );
    }

    #[test]
    fn controlled_pause_gates_next_chapter_and_resume_or_cancel_wakes_worker() {
        use std::sync::mpsc;
        use std::time::Duration;

        for cancel_while_paused in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let input = temp.path().join("paused.epub");
            write_test_epub_chapters(&input, 2);
            let paths = crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            );
            let output = paths.output_dir.join("paused-job");
            fs::create_dir_all(&output).unwrap();
            let book = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
            for (position, chapter) in book.chapters.iter().enumerate() {
                write_test_wav(&output.join(format!(
                    "{:04}-{}.mp3",
                    position + 1,
                    sanitize(&chapter.name)
                )));
            }
            let control = ConversionControl::new();
            let callback_control = control.clone();
            let (events_tx, events_rx) = mpsc::channel();
            let worker = ConversionWorker::new(AppConfig::from_paths(paths))
                .unwrap()
                .with_control(control.clone())
                .with_chapter_completed(Arc::new(move |event| {
                    if event.chapter_index == 0 {
                        callback_control.set_paused(true);
                    }
                    events_tx.send(event.chapter_index).unwrap();
                }));
            let jobs = worker.jobs.clone();
            let request = ConversionRequest {
                input,
                job_id: "paused-job".into(),
                engine: Some("edge".into()),
                voice: None,
                language: None,
                chapter_indices: None,
                no_parallel: true,
            };
            std::thread::scope(|scope| {
                let (result_tx, result_rx) = mpsc::channel();
                let running = scope.spawn(move || {
                    result_tx.send(worker.run(request)).unwrap();
                });
                let first = events_rx.recv_timeout(Duration::from_secs(5));
                let blocked = events_rx.recv_timeout(Duration::from_millis(50)).is_err();
                if cancel_while_paused {
                    control.cancel();
                } else {
                    control.set_paused(false);
                }
                let result = result_rx.recv_timeout(Duration::from_secs(5));
                // Always release the gate before assertions so a failed test
                // cannot leave its scoped worker blocked during unwinding.
                control.set_paused(false);
                running.join().unwrap();
                assert_eq!(first.unwrap(), 0);
                assert!(
                    blocked,
                    "paused conversion must not publish the next chapter"
                );
                let result = result.expect("resume or cancellation must wake the paused worker");
                if cancel_while_paused {
                    assert!(matches!(result, Err(WorkerError::Cancelled)));
                    assert_eq!(jobs.load("paused-job").unwrap().state, JobState::Cancelled);
                    assert!(!output.join("manifest.json").exists());
                } else {
                    assert!(
                        result.is_ok(),
                        "resumed cached conversion should finish: {result:?}"
                    );
                    assert_eq!(events_rx.recv_timeout(Duration::from_secs(1)).unwrap(), 1);
                    assert_eq!(jobs.load("paused-job").unwrap().state, JobState::Completed);
                }
            });
        }
    }

    #[test]
    fn failure_is_durable_before_callback() {
        let temp = tempfile::tempdir().unwrap();
        let paths = crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        );
        let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
        let observed_jobs = worker.jobs.clone();
        let worker = worker.with_progress(Arc::new(move |event| {
            if event.state == "failed" {
                assert_eq!(
                    observed_jobs.load(&event.job_id).unwrap().state,
                    JobState::Failed
                );
            }
        }));
        let result = worker.run(ConversionRequest {
            input: temp.path().join("missing.epub"),
            job_id: "failed-job".into(),
            engine: Some("edge".into()),
            voice: None,
            language: None,
            chapter_indices: None,
            no_parallel: true,
        });
        assert!(matches!(result, Err(WorkerError::Io(_))));
    }

    #[test]
    fn chapter_journal_is_durable_before_callback_and_preserves_partial_audio() {
        let temp = tempfile::tempdir().unwrap();
        let first = temp.path().join("first.mp3");
        let second = temp.path().join("invalid.mp3");
        write_test_wav(&first);
        fs::write(&second, b"invalid").unwrap();
        let path = temp.path().join("chapters.json");
        let journal = Mutex::new(ChapterJournal {
            schema_version: 1,
            source_sha256: None,
            source_chapters_total: None,
            job_id: "stream-test".into(),
            book_title: "Fixture".into(),
            book_author: "Author".into(),
            chapters_total: 2,
            chapters: Vec::new(),
        });
        let callback_path = path.clone();
        let sink: ChapterCompletionSink = Arc::new(move |item| {
            let persisted: ChapterJournal = cache::read_json(&callback_path).unwrap();
            assert_eq!(persisted.schema_version, 1);
            assert_eq!(persisted.chapters[0], item);
        });
        persist_chapter_and_emit(&path, &journal, event(8, first.clone()), Some(&sink)).unwrap();
        assert_eq!(
            chapter_output_path(temp.path(), "changed-position.mp3", 8, &journal).unwrap(),
            first,
            "a validated source chapter keeps its existing audio path"
        );
        assert!(persist_chapter_and_emit(&path, &journal, event(9, second), Some(&sink)).is_err());
        let persisted: ChapterJournal = cache::read_json(&path).unwrap();
        assert_eq!(persisted.chapters.len(), 1);
        assert_eq!(persisted.chapters[0].chapter_index, 8);
        assert_eq!(persisted.chapters[0].audio_path, first);
        assert!(!temp.path().join("manifest.json").exists());
    }

    #[test]
    fn interrupted_conversion_keeps_validated_partial_journal_without_terminal_manifest() {
        for cancel_after_first in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let input = temp.path().join("partial.epub");
            write_test_epub_chapters(&input, 2);
            let paths = crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            );
            let output_directory = paths.output_dir.join("partial-job");
            fs::create_dir_all(&output_directory).unwrap();
            let book = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
            assert_eq!(book.chapters.len(), 2);
            for (position, chapter) in book.chapters.iter().enumerate() {
                let path = output_directory.join(format!(
                    "{:04}-{}.mp3",
                    position + 1,
                    sanitize(&chapter.name)
                ));
                if position == 0 {
                    write_test_wav(&path);
                } else {
                    fs::write(path, b"invalid second chapter").unwrap();
                }
            }
            let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
            let cancel = worker.cancel.clone();
            let worker = worker.with_chapter_completed(Arc::new(move |_| {
                if cancel_after_first {
                    cancel.cancel();
                }
            }));
            let result = worker.run(ConversionRequest {
                input,
                job_id: "partial-job".into(),
                engine: Some("edge".into()),
                voice: None,
                language: None,
                chapter_indices: None,
                no_parallel: true,
            });
            if cancel_after_first {
                assert!(matches!(result, Err(WorkerError::Cancelled)));
            } else {
                assert!(matches!(result, Err(WorkerError::Audio(_))));
            }
            let journal: ChapterJournal =
                cache::read_json(output_directory.join("chapters.json")).unwrap();
            assert_eq!(journal.chapters_total, 2);
            assert_eq!(journal.chapters.len(), 1);
            assert_eq!(journal.chapters[0].chapter_index, 0);
            assert!(!output_directory.join("manifest.json").exists());
        }
    }

    #[test]
    fn parallel_chapter_publication_keeps_every_stable_source_index() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("chapter.mp3");
        write_test_wav(&audio);
        let path = temp.path().join("chapters.json");
        let journal = Mutex::new(ChapterJournal {
            schema_version: 1,
            source_sha256: None,
            source_chapters_total: None,
            job_id: "stream-test".into(),
            book_title: "Fixture".into(),
            book_author: "Author".into(),
            chapters_total: 4,
            chapters: Vec::new(),
        });
        std::thread::scope(|scope| {
            for index in [9, 2, 7, 4] {
                let path = &path;
                let journal = &journal;
                let audio = audio.clone();
                scope.spawn(move || {
                    persist_chapter_and_emit(path, journal, event(index, audio), None).unwrap();
                });
            }
        });
        let persisted: ChapterJournal = cache::read_json(&path).unwrap();
        assert_eq!(
            persisted
                .chapters
                .iter()
                .map(|chapter| chapter.chapter_index)
                .collect::<Vec<_>>(),
            vec![2, 4, 7, 9]
        );
    }

    #[test]
    fn resumed_later_selection_with_same_title_preserves_distinct_source_audio() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("resume-partial.epub");
        write_test_epub_chapters_with_titles(&input, 2, true);
        let paths = crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        );
        let output_directory = paths.output_dir.join("resume-partial");
        fs::create_dir_all(&output_directory).unwrap();
        let book = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
        let first_name = format!("0001-{}.mp3", sanitize(&book.chapters[0].name));
        let first_path = output_directory.join(&first_name);
        write_test_wav(&first_path);
        let original_first_audio = fs::read(&first_path).unwrap();
        assert_eq!(book.chapters[0].name, book.chapters[1].name);
        let journal = ChapterJournal {
            schema_version: 1,
            source_sha256: None,
            source_chapters_total: None,
            job_id: "resume-partial".into(),
            book_title: book.title.clone(),
            book_author: book.author.clone(),
            chapters_total: 2,
            chapters: vec![ChapterCompletionEvent {
                job_id: "resume-partial".into(),
                book_title: book.title.clone(),
                book_author: book.author.clone(),
                chapter_index: 0,
                chapters_total: 2,
                chapters_completed: 1,
                chapter_title: book.chapters[0].name.clone(),
                filename: first_name,
                audio_path: first_path.clone(),
                text_chars: book.chapters[0].text.chars().count(),
            }],
        };
        cache::atomic_write_json(output_directory.join("chapters.json"), &journal).unwrap();
        let later_path = output_directory.join(format!(
            "source-0001-0001-{}.mp3",
            sanitize(&book.chapters[1].name)
        ));
        write_test_wav(&later_path);
        let mut later_bytes = fs::read(&later_path).unwrap();
        *later_bytes.last_mut().unwrap() = 1;
        fs::write(&later_path, &later_bytes).unwrap();
        let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
        let metadata = serde_json::json!({
            "input": input,
            "engine": "edge",
            "voice": null,
            "language": null
        })
        .as_object()
        .unwrap()
        .clone();
        worker
            .jobs
            .create(JobRecord::new("resume-partial", metadata))
            .unwrap();
        worker
            .jobs
            .transition("resume-partial", JobState::Running)
            .unwrap();
        let observed_path = output_directory.join("chapters.json");
        let worker = worker.with_chapter_completed(Arc::new(move |event| {
            assert_eq!(event.chapter_index, 1);
            let journal: ChapterJournal = cache::read_json(&observed_path).unwrap();
            assert_eq!(journal.chapters_total, 2);
            assert_eq!(journal.chapters.len(), 2);
            assert_eq!(journal.chapters[0].chapter_index, 0);
            assert_eq!(journal.chapters[1].chapter_index, 1);
        }));
        let result = worker.run(ConversionRequest {
            input,
            job_id: "resume-partial".into(),
            engine: Some("edge".into()),
            voice: None,
            language: None,
            chapter_indices: Some(vec!["position:1".into()]),
            no_parallel: true,
        });
        assert!(result.is_ok(), "resume should retain journal: {result:?}");
        assert!(first_path.is_file());
        assert_eq!(fs::read(&first_path).unwrap(), original_first_audio);
        assert_eq!(fs::read(&later_path).unwrap(), later_bytes);
        let manifest = result.unwrap();
        assert_eq!(manifest.chapters.len(), 1);
        assert_eq!(manifest.chapters[0].source_index, 1);
        assert!(manifest.chapters[0].filename.starts_with("source-0001-"));
    }

    #[test]
    fn journal_recovery_rejects_wrong_identity_and_audio_outside_output() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("identity.epub");
        write_test_epub(&input);
        let book = epub::parse_epub(fs::File::open(input).unwrap()).unwrap();
        let output = temp.path().join("output");
        fs::create_dir_all(&output).unwrap();
        let audio = temp.path().join("outside.mp3");
        write_test_wav(&audio);
        let path = output.join("chapters.json");
        let mut journal = ChapterJournal {
            schema_version: 1,
            source_sha256: None,
            source_chapters_total: None,
            job_id: "expected".into(),
            book_title: book.title.clone(),
            book_author: book.author.clone(),
            chapters_total: 1,
            chapters: vec![ChapterCompletionEvent {
                job_id: "expected".into(),
                book_title: book.title.clone(),
                book_author: book.author.clone(),
                chapter_index: 0,
                chapters_total: 1,
                chapters_completed: 1,
                chapter_title: book.chapters[0].name.clone(),
                filename: "outside.mp3".into(),
                audio_path: audio,
                text_chars: book.chapters[0].text.chars().count(),
            }],
        };
        cache::atomic_write_json(&path, &journal).unwrap();
        assert!(
            recover_chapter_journal(&path, &output, "expected", &book, 1)
                .unwrap()
                .chapters
                .is_empty()
        );
        journal.job_id = "another-session".into();
        cache::atomic_write_json(&path, &journal).unwrap();
        assert!(recover_chapter_journal(&path, &output, "expected", &book, 1).is_err());
        assert_eq!(
            cache::read_json::<ChapterJournal>(&path).unwrap().job_id,
            "another-session"
        );
    }

    #[test]
    fn successor_retry_reuses_valid_audio_and_preserves_terminal_source_records() {
        for source_state in [JobState::Failed, JobState::Cancelled, JobState::Completed] {
            let temp = tempfile::tempdir().unwrap();
            let input = temp.path().join("retry.epub");
            write_test_epub_chapters(&input, 2);
            let paths = crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            );
            let source_output = paths.output_dir.join("old-job");
            fs::create_dir_all(&source_output).unwrap();
            let book = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
            let audio = source_output.join("original.mp3");
            write_test_wav(&audio);
            let audio_hash = cache::sha256_file(&audio).unwrap();
            let event = ChapterCompletionEvent {
                job_id: "old-job".into(),
                book_title: book.title.clone(),
                book_author: book.author.clone(),
                chapter_index: 0,
                chapters_total: 2,
                chapters_completed: 1,
                chapter_title: book.chapters[0].name.clone(),
                filename: "original.mp3".into(),
                audio_path: audio.clone(),
                text_chars: book.chapters[0].text.chars().count(),
            };
            let source_journal = ChapterJournal {
                schema_version: 1,
                source_sha256: None,
                source_chapters_total: None,
                job_id: "old-job".into(),
                book_title: book.title.clone(),
                book_author: book.author.clone(),
                chapters_total: 2,
                chapters: if source_state == JobState::Completed {
                    Vec::new()
                } else {
                    vec![event]
                },
            };
            let source_journal_path = source_output.join("chapters.json");
            cache::atomic_write_json(&source_journal_path, &source_journal).unwrap();
            if source_state == JobState::Completed {
                cache::atomic_write_json(
                    source_output.join("manifest.json"),
                    &OutputManifest {
                        source_chapters_total: None,
                        job_id: "old-job".into(),
                        title: book.title.clone(),
                        author: book.author.clone(),
                        chapters: book
                            .chapters
                            .iter()
                            .enumerate()
                            .map(|(index, chapter)| ChapterMetadata {
                                index: index + 1,
                                source_index: index,
                                title: chapter.name.clone(),
                                filename: if index == 0 {
                                    "original.mp3".into()
                                } else {
                                    "missing.mp3".into()
                                },
                                text_chars: chapter.text.chars().count(),
                            })
                            .collect(),
                        archive: "original.zip".into(),
                        cover: None,
                    },
                )
                .unwrap();
            }
            let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
            let metadata =
                serde_json::json!({"input":input,"engine":"edge","voice":null,"language":null})
                    .as_object()
                    .unwrap()
                    .clone();
            worker
                .jobs
                .create(JobRecord::new("old-job", metadata))
                .unwrap();
            worker
                .jobs
                .transition("old-job", JobState::Running)
                .unwrap();
            if source_state == JobState::Cancelled {
                worker.jobs.request_cancellation("old-job").unwrap();
            }
            worker.jobs.transition("old-job", source_state).unwrap();
            let old_record = worker.jobs.load("old-job").unwrap();
            let old_journal_bytes = fs::read(&source_journal_path).unwrap();
            let old_manifest_bytes = fs::read(source_output.join("manifest.json")).ok();
            let control = ConversionControl::new();
            control.set_recovery_job("old-job").unwrap();
            let result = worker
                .with_control(control)
                .run(ConversionRequest {
                    input,
                    job_id: "successor-job".into(),
                    engine: Some("edge".into()),
                    voice: None,
                    language: None,
                    chapter_indices: Some(vec!["position:0".into()]),
                    no_parallel: true,
                })
                .unwrap();
            assert_eq!(result.chapters.len(), 1);
            assert_eq!(result.source_chapters_total, Some(2));
            assert_eq!(result.chapters[0].source_index, 0);
            let destination = source_output
                .parent()
                .unwrap()
                .join("successor-job")
                .join(&result.chapters[0].filename);
            assert_eq!(cache::sha256_file(destination).unwrap(), audio_hash);
            assert_eq!(cache::sha256_file(&audio).unwrap(), audio_hash);
            assert_eq!(fs::read(&source_journal_path).unwrap(), old_journal_bytes);
            assert_eq!(
                fs::read(source_output.join("manifest.json")).ok(),
                old_manifest_bytes
            );
            let manager = JobManager::new(temp.path().join(".jobs")).unwrap();
            assert_eq!(manager.load("old-job").unwrap(), old_record);
            assert_eq!(
                manager.load("successor-job").unwrap().state,
                JobState::Completed
            );
            assert!(manager
                .load("successor-job")
                .unwrap()
                .metadata
                .contains_key("chapterIndices"));
            assert_eq!(
                manager.load("successor-job").unwrap().metadata["recoveryJobId"],
                "old-job"
            );
            let journal: ChapterJournal = cache::read_json(
                source_output
                    .parent()
                    .unwrap()
                    .join("successor-job/chapters.json"),
            )
            .unwrap();
            assert_eq!(journal.chapters.len(), 1);
            assert_eq!(journal.source_chapters_total, Some(2));
            assert_eq!(journal.chapters_total, 1);
            assert!(journal.source_sha256.is_some());
        }
    }

    #[test]
    fn legacy_manifest_and_journal_decode_without_source_chapter_count() {
        let manifest: OutputManifest = serde_json::from_value(serde_json::json!({
            "jobId":"legacy-job", "title":"Legacy", "author":"Author",
            "chapters":[], "archive":"legacy.zip", "cover":null
        }))
        .unwrap();
        assert_eq!(manifest.source_chapters_total, None);
        let journal: ChapterJournal = serde_json::from_value(serde_json::json!({
            "schemaVersion":1, "jobId":"legacy-job", "bookTitle":"Legacy",
            "bookAuthor":"Author", "chaptersTotal":1, "chapters":[]
        }))
        .unwrap();
        assert_eq!(journal.source_chapters_total, None);
        assert!(serde_json::to_value(manifest)
            .unwrap()
            .get("sourceChaptersTotal")
            .is_none());
        assert!(serde_json::to_value(journal)
            .unwrap()
            .get("sourceChaptersTotal")
            .is_none());
    }

    #[test]
    fn successor_retry_rejects_wrong_source_hash_or_provider_without_changing_old_job() {
        for wrong_provider in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let input = temp.path().join("retry-rejected.epub");
            write_test_epub(&input);
            let paths = crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            );
            let source_output = paths.output_dir.join("old-job");
            fs::create_dir_all(&source_output).unwrap();
            let book = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
            let journal = ChapterJournal {
                schema_version: 1,
                source_sha256: Some("incorrect-source-hash".into()),
                source_chapters_total: None,
                job_id: "old-job".into(),
                book_title: book.title,
                book_author: book.author,
                chapters_total: 1,
                chapters: Vec::new(),
            };
            let journal_path = source_output.join("chapters.json");
            cache::atomic_write_json(&journal_path, &journal).unwrap();
            let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
            worker
                .jobs
                .create(JobRecord::new(
                    "old-job",
                    serde_json::json!({"input":input,"engine":"edge","voice":null,"language":null})
                        .as_object()
                        .unwrap()
                        .clone(),
                ))
                .unwrap();
            worker
                .jobs
                .transition("old-job", JobState::Running)
                .unwrap();
            worker.jobs.transition("old-job", JobState::Failed).unwrap();
            let original_record = worker.jobs.load("old-job").unwrap();
            let original_journal = fs::read(&journal_path).unwrap();
            let manager = worker.jobs.clone();
            let control = ConversionControl::new();
            control.set_recovery_job("old-job").unwrap();
            let result = worker.with_control(control).run(ConversionRequest {
                input,
                job_id: "rejected-successor".into(),
                engine: Some(if wrong_provider { "piper" } else { "edge" }.into()),
                voice: None,
                language: None,
                chapter_indices: None,
                no_parallel: true,
            });
            assert!(matches!(result, Err(WorkerError::Piper(_))));
            assert_eq!(manager.load("old-job").unwrap(), original_record);
            assert_eq!(fs::read(&journal_path).unwrap(), original_journal);
        }
    }

    #[cfg(unix)]
    #[test]
    fn successor_retry_rejects_external_destination_symlink_without_mutating_data() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("symlink-retry.epub");
        write_test_epub(&input);
        let paths = crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        );
        let source_output = paths.output_dir.join("old-job");
        let successor_output = paths.output_dir.join("successor-job");
        fs::create_dir_all(&source_output).unwrap();
        fs::create_dir_all(&successor_output).unwrap();
        let book = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
        let audio = source_output.join("original.mp3");
        write_test_wav(&audio);
        let outsider = temp.path().join("outside.mp3");
        fs::copy(&audio, &outsider).unwrap();
        let outsider_hash = cache::sha256_file(&outsider).unwrap();
        let journal = ChapterJournal {
            schema_version: 1,
            source_sha256: Some(cache::sha256_file(&input).unwrap()),
            source_chapters_total: None,
            job_id: "old-job".into(),
            book_title: book.title.clone(),
            book_author: book.author.clone(),
            chapters_total: 1,
            chapters: vec![ChapterCompletionEvent {
                job_id: "old-job".into(),
                book_title: book.title.clone(),
                book_author: book.author.clone(),
                chapter_index: 0,
                chapters_total: 1,
                chapters_completed: 1,
                chapter_title: book.chapters[0].name.clone(),
                filename: "original.mp3".into(),
                audio_path: audio.clone(),
                text_chars: book.chapters[0].text.chars().count(),
            }],
        };
        let journal_path = source_output.join("chapters.json");
        cache::atomic_write_json(&journal_path, &journal).unwrap();
        let original_journal = fs::read(&journal_path).unwrap();
        let destination = successor_output.join(format!(
            "source-0000-{}.mp3",
            sanitize(&book.chapters[0].name)
        ));
        std::os::unix::fs::symlink(&outsider, &destination).unwrap();
        let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
        worker
            .jobs
            .create(JobRecord::new(
                "old-job",
                serde_json::json!({"input":input,"engine":"edge","voice":null,"language":null})
                    .as_object()
                    .unwrap()
                    .clone(),
            ))
            .unwrap();
        worker
            .jobs
            .transition("old-job", JobState::Running)
            .unwrap();
        worker.jobs.transition("old-job", JobState::Failed).unwrap();
        let manager = worker.jobs.clone();
        let original_record = manager.load("old-job").unwrap();
        let control = ConversionControl::new();
        control.set_recovery_job("old-job").unwrap();
        let result = worker.with_control(control).run(ConversionRequest {
            input,
            job_id: "successor-job".into(),
            engine: Some("edge".into()),
            voice: None,
            language: None,
            chapter_indices: None,
            no_parallel: true,
        });
        assert!(matches!(result, Err(WorkerError::Piper(_))));
        assert_eq!(cache::sha256_file(&outsider).unwrap(), outsider_hash);
        assert_eq!(cache::sha256_file(&audio).unwrap(), outsider_hash);
        assert_eq!(manager.load("old-job").unwrap(), original_record);
        assert_eq!(fs::read(journal_path).unwrap(), original_journal);
        assert!(fs::symlink_metadata(&destination)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!successor_output.join("chapters.json").exists());
        assert!(!successor_output.join("manifest.json").exists());
    }

    #[test]
    fn validated_chapters_are_published_in_conversion_order() {
        let temp = tempfile::tempdir().unwrap();
        let first = temp.path().join("first.mp3");
        let second = temp.path().join("second.mp3");
        write_test_wav(&first);
        write_test_wav(&second);
        let observed = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&observed);
        let sink: ChapterCompletionSink = Arc::new(move |item| {
            captured.lock().unwrap().push(item.chapter_index);
        });

        let path = temp.path().join("chapters.json");
        let journal = test_journal(2);
        persist_chapter_and_emit(&path, &journal, event(0, first.clone()), Some(&sink)).unwrap();
        persist_chapter_and_emit(&path, &journal, event(1, second.clone()), Some(&sink)).unwrap();

        assert_eq!(*observed.lock().unwrap(), vec![0, 1]);
    }

    #[test]
    fn invalid_audio_is_never_published_to_playback() {
        let temp = tempfile::tempdir().unwrap();
        let invalid = temp.path().join("invalid.mp3");
        fs::write(&invalid, b"not audio").unwrap();
        let published = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let captured = Arc::clone(&published);
        let sink: ChapterCompletionSink = Arc::new(move |_| {
            captured.store(true, std::sync::atomic::Ordering::Release);
        });

        assert!(persist_chapter_and_emit(
            &temp.path().join("chapters.json"),
            &test_journal(2),
            event(0, invalid.clone()),
            Some(&sink)
        )
        .is_err());
        assert!(!published.load(std::sync::atomic::Ordering::Acquire));
    }

    #[test]
    fn positional_selector_does_not_collide_with_numeric_toc_index() {
        assert!(!chapter_matches_selector("position:1", "1", 0));
        assert!(chapter_matches_selector("position:1", "2", 1));
        assert!(!chapter_matches_selector("position:1", "3", 2));
        assert!(chapter_matches_selector("toc:1", "1", 0));
        assert!(!chapter_matches_selector("toc:1", "2", 1));
    }

    #[test]
    fn chapter_parallelism_honors_serial_mode_and_all_caps() {
        assert_eq!(resolve_chapter_parallelism(true, 8, 4, 2), 1);
        assert_eq!(resolve_chapter_parallelism(false, 8, 4, 2), 2);
        assert_eq!(resolve_chapter_parallelism(false, 2, 8, 8), 2);
        assert_eq!(resolve_chapter_parallelism(false, 8, 8, 0), 1);
    }
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
