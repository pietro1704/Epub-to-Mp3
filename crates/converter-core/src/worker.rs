//! End-to-end conversion orchestration shared by the CLI and HTTP server.
use crate::{
    audio::{self, ChapterMetadata},
    cache,
    config::AppConfig,
    epub,
    jobs::{JobError, JobManager, JobRecord, JobState},
    piper::{self, CancellationToken, PiperConfig},
    tts::EdgeError,
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
}
pub type ProgressSink = Arc<dyn Fn(ProgressEvent) + Send + Sync>;

pub struct ConversionWorker {
    pub config: AppConfig,
    pub jobs: JobManager,
    pub cancel: CancellationToken,
    pub progress: Option<ProgressSink>,
}
impl ConversionWorker {
    pub fn new(config: AppConfig) -> Result<Self, WorkerError> {
        let jobs = JobManager::new(&config.paths.jobs_dir)?;
        Ok(Self {
            config,
            jobs,
            cancel: CancellationToken::default(),
            progress: None,
        })
    }
    pub fn with_progress(mut self, sink: ProgressSink) -> Self {
        self.progress = Some(sink);
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
        self.jobs.create(JobRecord::new(
            &request.job_id,
            metadata.as_object().cloned().unwrap_or_default(),
        ))?;
        self.jobs.transition(&request.job_id, JobState::Running)?;
        let result = self.run_inner(&request);
        match &result {
            Ok(_) => {
                self.jobs.transition(&request.job_id, JobState::Completed)?;
            }
            Err(WorkerError::Cancelled) => {
                let _ = self.jobs.transition(&request.job_id, JobState::Cancelled);
            }
            Err(_) => {
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
                        wanted.iter().any(|value| {
                            value == &chapter.index
                                || value
                                    .parse::<usize>()
                                    .map(|index| index == *position)
                                    .unwrap_or(false)
                        })
                    })
                    .unwrap_or(true)
            })
            .map(|(_, chapter)| chapter)
            .collect();
        let total = chapters.len();
        let source_text_chars: usize = chapters
            .iter()
            .map(|chapter| chapter.text.chars().count())
            .sum();
        if total == 0 || source_text_chars == 0 {
            return Err(WorkerError::Piper(
                "selected chapters have no readable text".into(),
            ));
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
        let parallelism = if request.no_parallel {
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
            configured.min(self.config.max_parallel).min(cap).max(1)
        };
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(parallelism)
            .build()
            .map_err(|error| WorkerError::Piper(error.to_string()))?;
        let results = Mutex::new(Vec::with_capacity(total));
        pool.install(|| {
            chapters.par_iter().enumerate().try_for_each(
                |(position, chapter)| -> Result<(), WorkerError> {
                    if self.cancel.is_cancelled()
                        || self.jobs.is_cancellation_requested(&request.job_id)?
                    {
                        return Err(WorkerError::Cancelled);
                    }
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
                    let mp3 = output_dir.join(format!("{stem}.mp3"));
                    let language = detected_language;
                    let engine = select_engine(request.engine.as_deref(), &self.config);
                    if !mp3.is_file() {
                        eprintln!("synthesizing chapter {}/{}", position + 1, total);
                        self.synthesize_with_timeout(
                            &engine,
                            &text,
                            &mp3,
                            request.voice.as_deref(),
                            request.language.as_deref().or(language),
                        )?;
                    }
                    let name = mp3.file_name().unwrap().to_string_lossy().to_string();
                    results.lock().unwrap().push((
                        position,
                        mp3,
                        name.clone(),
                        ChapterMetadata {
                            index: position + 1,
                            title: chapter.name.clone(),
                            filename: name,
                            text_chars: text.chars().count(),
                        },
                    ));
                    Ok(())
                },
            )
        })?;
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
    ) -> Result<(), WorkerError> {
        if engine == "edge" {
            let voice = voice.unwrap_or_else(|| default_edge_voice(language));
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            match rt.block_on(crate::tts::synthesize_with_reference_client(text, voice)) {
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
    ) -> Result<(), WorkerError> {
        let timeout_secs = std::env::var("RUST_CHAPTER_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(if cfg!(target_os = "android") {
                300
            } else {
                180
            });
        let result = std::thread::scope(|scope| {
            let handle = scope.spawn(|| self.synthesize(engine, text, out, voice, language));
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
