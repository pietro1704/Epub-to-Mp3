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
                    let language = request.language.as_deref().or(language);
                    let request_key = chapter_audio_request_key(
                        &book_key,
                        &chapter.index,
                        &text,
                        &engine,
                        request.voice.as_deref(),
                        language,
                    )?;
                    ensure_chapter_audio(&mp3, &request_key, |pending| {
                        eprintln!("synthesizing chapter {}/{}", position + 1, total);
                        self.synthesize_with_timeout(
                            &engine,
                            &text,
                            pending,
                            request.voice.as_deref(),
                            language,
                        )?;
                        if self.cancel.is_cancelled()
                            || self.jobs.is_cancellation_requested(&request.job_id)?
                        {
                            return Err(WorkerError::Cancelled);
                        }
                        Ok(())
                    })?;
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
        timeout: std::time::Duration,
    ) -> Result<(), WorkerError> {
        if engine == "edge" {
            let voice = voice.unwrap_or_else(|| default_edge_voice(language));
            match run_edge_synthesis(
                crate::tts::synthesize_with_reference_client(text, voice),
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
        let timeout = std::time::Duration::from_secs(timeout_secs);
        if engine == "edge" {
            return self.synthesize(engine, text, out, voice, language, timeout);
        }
        let result = std::thread::scope(|scope| {
            let handle =
                scope.spawn(|| self.synthesize(engine, text, out, voice, language, timeout));
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
    if receipt.version != 1 || receipt.request_key != request_key || receipt.size == 0 {
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
    if chapter_audio_is_complete(output, request_key) {
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
    let metadata = fs::metadata(&pending)?;
    if !metadata.is_file() || metadata.len() == 0 {
        return Err(WorkerError::Audio(audio::AudioError::Validation(
            "synthesis produced an empty audio artifact".into(),
        )));
    }
    let receipt = ChapterAudioReceipt {
        version: 1,
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

fn run_edge_synthesis<F>(
    synthesis: F,
    cancel: &CancellationToken,
    timeout: std::time::Duration,
) -> Result<Vec<u8>, WorkerError>
where
    F: std::future::Future<Output = Result<Vec<u8>, EdgeError>>,
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
    use super::*;

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

        let request = ConversionRequest {
            input,
            job_id: "proven-existing-audio".into(),
            engine: Some("piper".into()),
            voice: None,
            language: Some("en".into()),
            chapter_indices: Some(vec!["0".into()]),
            no_parallel: true,
        };
        let manifest = worker.run(request.clone()).unwrap();
        assert_eq!(manifest.chapters.len(), 1);
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
            input,
            job_id: "empty-existing-audio".into(),
            engine: Some("piper".into()),
            voice: None,
            language: Some("en".into()),
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
    fn edge_synthesis_panic_remains_a_typed_worker_error() {
        let result = run_edge_synthesis(
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
        let result = run_edge_synthesis(
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
        let result = run_edge_synthesis(
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
            run_edge_synthesis(async { Err(EdgeError::NoAudio) }, &cancel, timeout),
            Err(WorkerError::Edge(EdgeError::NoAudio))
        ));
    }
}
