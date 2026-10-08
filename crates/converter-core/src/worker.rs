//! End-to-end conversion orchestration shared by the CLI and HTTP server.
use crate::{
    audio::{self, ChapterMetadata},
    cache,
    config::AppConfig,
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
    #[error("cancelled")]
    Cancelled,
    #[error("unsupported input: {0}")]
    Unsupported(String),
    #[error("unsupported conversion engine '{0}'; supported engines: edge, piper, auto")]
    UnsupportedEngine(String),
}
pub type ProgressSink = Arc<dyn Fn(ProgressEvent) + Send + Sync>;
pub type ChapterCompletionSink = Arc<dyn Fn(ChapterCompletionEvent) + Send + Sync>;

/// Per-invocation controls. Defaults retain resume and serial-selection behavior.
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
        resolve_chapter_parallelism(
            no_parallel && !self.max_performance,
            configured,
            maximum,
            cap,
        )
    }
}

pub struct ConversionWorker {
    pub config: AppConfig,
    pub jobs: JobManager,
    pub cancel: CancellationToken,
    pub progress: Option<ProgressSink>,
    pub chapter_completed: Option<ChapterCompletionSink>,
    pub adaptive: Arc<crate::adaptive::AdaptiveThroughputController>,
    pub execution_options: ExecutionOptions,
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
            progress: None,
            chapter_completed: None,
            adaptive,
            execution_options: ExecutionOptions::default(),
        })
    }
    pub fn with_progress(mut self, sink: ProgressSink) -> Self {
        self.progress = Some(sink);
        self
    }
    pub fn with_execution_options(mut self, options: ExecutionOptions) -> Self {
        self.execution_options = options;
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
    pub fn cancel(&self) {
        self.cancel.cancel();
    }
    pub fn run(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        let metadata = serde_json::json!({"input":request.input,"engine":request.engine,"voice":request.voice,"language":request.language});
        let metadata = metadata.as_object().cloned().unwrap_or_default();
        match self.jobs.load(&request.job_id) {
            Ok(record) => {
                if record.metadata != metadata {
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
                self.jobs.transition(&request.job_id, JobState::Completed)?;
            }
            Err(WorkerError::Cancelled) => {
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
                let _ = self.jobs.transition(&request.job_id, JobState::Cancelled);
            }
            Err(_) => {
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
                let _ = self.jobs.transition(&request.job_id, JobState::Failed);
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
        let parallelism = self.execution_options.chapter_parallelism(
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
        let completed_chapters = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        pool.install(|| {
            chapters.par_iter().enumerate().try_for_each(
                |(position, (source_position, chapter))| -> Result<(), WorkerError> {
                    let source_position = *source_position;
                    let chapter = *chapter;
                    if self.cancel.is_cancelled()
                        || self.jobs.is_cancellation_requested(&request.job_id)?
                    {
                        return Err(WorkerError::Cancelled);
                    }
                    let text_path =
                        cache_dir.join(format!("{}.json", chapter.index.replace('.', "_")));
                    let text = if self.execution_options.clear_cache {
                        cache::refresh_chapter_text(
                            &self.config.paths.cache_dir,
                            &book_key,
                            &format!("{}.json", chapter.index.replace('.', "_")),
                            &chapter.text,
                        )?
                    } else if text_path.is_file() {
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
                    let mp3 = output_dir.join(format!("{stem}.mp3"));
                    let language = detected_language;
                    let engine = select_engine(request.engine.as_deref(), &self.config)?;
                    self.emit(ProgressEvent {
                        job_id: request.job_id.clone(),
                        state: "running".into(),
                        chapter_index: Some(position),
                        chapters_total: total,
                        chapters_completed: completed_chapters
                            .load(std::sync::atomic::Ordering::Acquire),
                        percent: completed_chapters.load(std::sync::atomic::Ordering::Acquire)
                            as f64
                            / total as f64
                            * 100.0,
                        engine: Some(engine.clone()),
                        message: format!("converting chapter {}", position + 1),
                    });
                    let synthesis_started = std::time::Instant::now();
                    let synthesized = self.execution_options.force_reprocess || !mp3.is_file();
                    if synthesized {
                        eprintln!("synthesizing chapter {}/{}", position + 1, total);
                        let synthesize = |target: &Path,
                                          staging_owner: Option<
                            Arc<cache::OwnedStagingDirectory>,
                        >| {
                            self.synthesize_with_timeout(
                                &engine,
                                &text,
                                target,
                                request.voice.as_deref(),
                                request.language.as_deref().or(language),
                                request.job_id.clone(),
                                position,
                                total,
                                Arc::clone(&completed_chapters),
                                staging_owner,
                            )
                        };
                        if self.execution_options.force_reprocess {
                            regenerate_chapter_audio(&mp3, |target, owner| {
                                synthesize(target, Some(owner))
                            })?;
                        } else {
                            synthesize(&mp3, None)?;
                        }
                    }
                    let chapter_name = chapter.name.clone();
                    let text_chars = text.chars().count();
                    let filename = mp3.file_name().unwrap().to_string_lossy().to_string();
                    let completed =
                        completed_chapters.fetch_add(1, std::sync::atomic::Ordering::AcqRel) + 1;
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
                    validate_chapter_and_emit(&mp3, event, self.chapter_completed.as_ref())?;
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
                    Ok(())
                },
            )
        })?;
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
        if let Some(cover_name) = cover
            .as_ref()
            .filter(|_| results.iter().any(|result| result.4))
        {
            let cover_path = output_dir.join(cover_name);
            let artwork = audio::CoverArtwork::read(&cover_path)?;
            for (_, path, _, _, synthesized) in &results {
                if *synthesized {
                    artwork.embed_into(path)?;
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
            let result = rt.block_on(crate::tts::synthesize_with_reference_client(
                text,
                voice,
                Arc::clone(&self.adaptive),
                telemetry,
            ));
            rt.shutdown_timeout(std::time::Duration::from_secs(1));
            match result {
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
                    return Err(WorkerError::Edge(error));
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
        staging_owner: Option<Arc<cache::OwnedStagingDirectory>>,
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
        let telemetry: Option<Telemetry> = progress.as_ref().map(|sink| {
            let sink = Arc::clone(sink);
            let job_id = job_id.clone();
            let completed_chapters = Arc::clone(&completed_chapters);
            Arc::new(move |event| {
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
                // A timed-out invocation may return before its worker stops.
                // Retain its exclusive directory until late writes and cleanup finish.
                let _staging_owner = staging_owner;
                let worker = Self::new(synthesis_config);
                let result = worker.map_or_else(Err, |mut worker| {
                    worker.cancel = cancel;
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
                if sender.send(result).is_err() {
                    let _ = fs::remove_file(&out_owned);
                }
            });
        if let Err(error) = spawn {
            return Err(WorkerError::Piper(format!(
                "failed to start synthesis thread: {error}"
            )));
        }
        match receiver.recv_timeout(std::time::Duration::from_secs(timeout_secs)) {
            Ok(Ok(())) => fs::rename(&temporary_output, out).map_err(WorkerError::Io),
            Ok(Err(error)) => {
                let _ = fs::remove_file(&temporary_output);
                Err(error)
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                self.cancel.cancel();
                Err(if engine == "edge" {
                    WorkerError::Edge(EdgeError::Transport("chapter synthesis timed out".into()))
                } else {
                    WorkerError::Piper("chapter synthesis timed out".into())
                })
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let _ = fs::remove_file(&temporary_output);
                Err(WorkerError::Piper(
                    "synthesis thread exited without a result".into(),
                ))
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

fn regenerate_chapter_audio(
    destination: &Path,
    synthesize: impl FnOnce(&Path, Arc<cache::OwnedStagingDirectory>) -> Result<(), WorkerError>,
) -> Result<(), WorkerError> {
    let parent = destination
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing audio parent"))?;
    let staging = Arc::new(cache::OwnedStagingDirectory::create(parent)?);
    let path = staging.0.join("chapter.mp3");
    synthesize(&path, Arc::clone(&staging))?;
    audio::validate_audio(&path, 100)?;
    fs::rename(path, destination)?;
    Ok(())
}

fn validate_chapter_and_emit(
    audio_path: &Path,
    event: ChapterCompletionEvent,
    sink: Option<&ChapterCompletionSink>,
) -> Result<(), WorkerError> {
    audio::validate_audio(audio_path, 100)?;
    if let Some(sink) = sink {
        sink(event);
    }
    Ok(())
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

    #[test]
    fn max_performance_preserves_configured_and_platform_resource_caps() {
        let normal = ExecutionOptions::default();
        let fast = ExecutionOptions {
            max_performance: true,
            ..normal
        };
        assert_eq!(normal.chapter_parallelism(true, 8, 8, 2), 1);
        assert_eq!(fast.chapter_parallelism(true, 8, 8, 2), 2);
        assert_eq!(fast.chapter_parallelism(true, 1, 8, 2), 1);
        assert_eq!(fast.chapter_parallelism(true, 8, 1, 2), 1);
        assert_eq!(fast.chapter_parallelism(true, 8, 8, 1), 1);
    }

    #[test]
    fn forced_audio_replacement_preserves_prior_bytes_on_failure_and_validates_before_publish() {
        let fixture = tempfile::tempdir().unwrap();
        let target = fixture.path().join("selected.mp3");
        let untouched = fixture.path().join("unselected.mp3");
        write_test_wav(&target);
        fs::write(&untouched, b"unselected download").unwrap();
        let prior = fs::read(&target).unwrap();
        let failed = regenerate_chapter_audio(&target, |path, _owner| {
            fs::write(path, b"partial new audio")?;
            Err(WorkerError::Cancelled)
        });
        assert!(failed.is_err());
        assert_eq!(fs::read(&target).unwrap(), prior);
        assert!(regenerate_chapter_audio(&target, |path, _owner| {
            fs::write(path, b"invalid")?;
            Ok(())
        })
        .is_err());
        assert_eq!(fs::read(&target).unwrap(), prior);
        regenerate_chapter_audio(&target, |path, _owner| {
            // A distinct, valid waveform must replace an already present chapter.
            write_test_wav(path);
            let mut waveform = fs::read(path)?;
            waveform[44] = 1;
            fs::write(path, waveform)?;
            Ok(())
        })
        .unwrap();
        assert_ne!(fs::read(&target).unwrap(), prior);
        assert_eq!(fs::read(untouched).unwrap(), b"unselected download");
        assert_eq!(fs::read_dir(fixture.path()).unwrap().count(), 2);
    }

    #[test]
    fn timed_out_regeneration_keeps_staging_owned_until_late_writer_stops() {
        let fixture = tempfile::tempdir().unwrap();
        let target = fixture.path().join("selected.mp3");
        fs::write(&target, b"prior audio").unwrap();
        let (started, stage_path) = std::sync::mpsc::channel();
        let (release, resume) = std::sync::mpsc::channel();
        let mut writer = None;
        let result = regenerate_chapter_audio(&target, |path, owner| {
            let path = path.to_owned();
            writer = Some(std::thread::spawn(move || {
                started.send(owner.0.clone()).unwrap();
                resume.recv().unwrap();
                // Model/runtime work may still return after its invocation timed out.
                fs::write(path, b"late owned bytes").unwrap();
                drop(owner);
            }));
            Err(WorkerError::Cancelled)
        });
        assert!(result.is_err());
        let staging = stage_path.recv().unwrap();
        assert!(staging.is_dir());
        assert_eq!(fs::read(&target).unwrap(), b"prior audio");
        release.send(()).unwrap();
        writer.unwrap().join().unwrap();
        assert!(!staging.exists());
        assert_eq!(fs::read(target).unwrap(), b"prior audio");
    }

    #[test]
    fn unsupported_engine_configuration_never_silently_selects_edge() {
        let root = PathBuf::from("/unused-engine-selection-fixture");
        let mut config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            [("OUTPUT_DIR".to_owned(), root.to_string_lossy().into_owned())],
            root,
        ));
        config.engine = "edge".into();
        for engine in ["coqui", "unknown", "kokoro-unsupported", ""] {
            assert!(
                select_engine(Some(engine), &config).is_err(),
                "unsupported requested engine {engine:?} silently selected Edge"
            );
        }
        config.engine = "unknown".into();
        assert!(
            select_engine(None, &config).is_err(),
            "unsupported configured engine selected Edge"
        );
        for (requested, expected) in [
            ("edge", "edge"),
            ("PIPER", "piper"),
            ("auto", "edge"),
            (" Edge ", "edge"),
        ] {
            assert_eq!(select_engine(Some(requested), &config).unwrap(), expected);
        }
        config.engine = "auto".into();
        assert_eq!(select_engine(None, &config).unwrap(), "edge");
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
        zip.write_all(br#"<package xmlns="http://www.idpf.org/2007/opf"><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Resume fixture</dc:title><dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Test</dc:creator></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#).unwrap();
        zip.start_file("OPS/chapter.xhtml", options).unwrap();
        zip.write_all(br#"<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Chapter One</h1><p>Existing validated audio can be resumed.</p></body></html>"#).unwrap();
        zip.finish().unwrap();
    }

    #[test]
    fn clear_cache_runs_at_selected_worker_boundary_without_rewriting_audio() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path();
        let input = root.join("source.epub");
        write_test_epub(&input);
        let source = fs::read(&input).unwrap();
        let key = cache::sha256_bytes(&source);
        let book = epub::parse_epub(std::io::Cursor::new(&source)).unwrap();
        let paths = crate::paths::resolve_paths_from(
            [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
            root.to_path_buf(),
        );
        let mut config = AppConfig::from_paths(paths);
        config.max_parallel = 1;
        let worker = ConversionWorker::new(config)
            .unwrap()
            .with_execution_options(ExecutionOptions {
                clear_cache: true,
                ..ExecutionOptions::default()
            });
        let cache_dir = worker.config.paths.cache_dir.join(&key);
        let output_dir = worker.config.paths.output_dir.join("refresh-job");
        fs::create_dir_all(&cache_dir).unwrap();
        fs::create_dir_all(&output_dir).unwrap();
        let chapter_file = format!("{}.json", book.chapters[0].index.replace('.', "_"));
        fs::write(cache_dir.join(&chapter_file), b"malformed derived cache").unwrap();
        let other = cache_dir.join("unselected.json");
        fs::write(&other, b"unselected derived text").unwrap();
        let audio = output_dir.join(format!("0001-{}.mp3", sanitize(&book.chapters[0].name)));
        // The real worker reuses this valid local waveform; no provider is contacted.
        write_test_wav(&audio);
        let prior_audio = fs::read(&audio).unwrap();
        let result = worker
            .run(ConversionRequest {
                input: input.clone(),
                job_id: "refresh-job".into(),
                engine: Some("edge".into()),
                voice: None,
                language: None,
                chapter_indices: Some(vec!["position:0".into()]),
                no_parallel: true,
            })
            .unwrap();
        assert_eq!(result.chapters.len(), 1);
        assert_eq!(result.chapters[0].source_index, 0);
        assert_eq!(
            cache::read_json::<String>(cache_dir.join(chapter_file)).unwrap(),
            book.chapters[0].text
        );
        assert_eq!(fs::read(other).unwrap(), b"unselected derived text");
        assert_eq!(fs::read(audio).unwrap(), prior_audio);
        assert_eq!(fs::read(input).unwrap(), source);
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

        validate_chapter_and_emit(&first, event(0, first.clone()), Some(&sink)).unwrap();
        validate_chapter_and_emit(&second, event(1, second.clone()), Some(&sink)).unwrap();

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

        assert!(
            validate_chapter_and_emit(&invalid, event(0, invalid.clone()), Some(&sink)).is_err()
        );
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

fn select_engine(request: Option<&str>, config: &AppConfig) -> Result<String, WorkerError> {
    let engine = request
        .unwrap_or(&config.engine)
        .trim()
        .to_ascii_lowercase();
    match engine.as_str() {
        "piper" => Ok("piper".into()),
        "edge" | "auto" => Ok("edge".into()),
        _ => Err(WorkerError::UnsupportedEngine(engine)),
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
