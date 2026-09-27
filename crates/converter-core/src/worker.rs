//! End-to-end conversion orchestration shared by the CLI and HTTP server.
use crate::{
    audio::{self, ChapterMetadata},
    cache,
    config::AppConfig,
    epub,
    jobs::{JobError, JobManager, JobRecord, JobState},
    piper::{self, CancellationToken, PiperConfig},
    tts::{EdgeConfig, EdgeError, EdgeTtsClient},
};
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::Arc,
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
        let book = epub::parse_epub(std::io::BufReader::new(fs::File::open(&request.input)?))?;
        let book_key = cache::sha256_file(&request.input)?;
        let cache_dir = self.config.paths.cache_dir.join(&book_key);
        let output_dir = self.config.paths.output_dir.join(&request.job_id);
        fs::create_dir_all(&cache_dir)?;
        fs::create_dir_all(&output_dir)?;
        let total = book.chapters.len();
        let mut files = Vec::with_capacity(total);
        let mut manifest = Vec::with_capacity(total);
        for (position, chapter) in book.chapters.iter().enumerate() {
            if self.cancel.is_cancelled() || self.jobs.is_cancellation_requested(&request.job_id)? {
                return Err(WorkerError::Cancelled);
            }
            let text_path = cache_dir.join(format!("{}.json", chapter.index.replace('.', "_")));
            let text = if text_path.is_file() {
                cache::read_json::<String>(&text_path)?
            } else {
                cache::atomic_write_json(&text_path, &chapter.text)?;
                chapter.text.clone()
            };
            let stem = format!("{:04}-{}", position + 1, sanitize(&chapter.name));
            let mp3 = output_dir.join(format!("{stem}.mp3"));
            let engine = select_engine(request.engine.as_deref(), &self.config);
            if !mp3.is_file() {
                self.synthesize(
                    &engine,
                    &text,
                    &mp3,
                    request.voice.as_deref(),
                    request.language.as_deref(),
                )?;
            }
            let name = mp3.file_name().unwrap().to_string_lossy().to_string();
            files.push((mp3.clone(), name.clone()));
            manifest.push(ChapterMetadata {
                index: position + 1,
                title: chapter.name.clone(),
                filename: name,
                text_chars: text.chars().count(),
            });
            let percent = ((position + 1) as f64 / (total.max(1) as f64)) * 100.0;
            self.emit(ProgressEvent {
                job_id: request.job_id.clone(),
                state: "running".into(),
                chapter_index: Some(position),
                chapters_total: total,
                chapters_completed: position + 1,
                percent,
                engine: Some(engine),
                message: format!("Converted chapter {}", position + 1),
            });
            self.jobs.update_progress(&request.job_id,serde_json::json!({"chaptersCompleted":position+1,"chaptersTotal":total,"percent":percent}))?;
        }
        let archive = output_dir.join(format!("{}.zip", sanitize(&book.title)));
        audio::create_archive(&archive, &files)?;
        let output_name = archive.file_name().unwrap().to_string_lossy().to_string();
        let result = OutputManifest {
            job_id: request.job_id.clone(),
            title: book.title,
            author: book.author,
            chapters: manifest,
            archive: output_name,
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
        _language: Option<&str>,
    ) -> Result<(), WorkerError> {
        if engine == "edge" {
            let voice = voice.unwrap_or("en-US-GuyNeural");
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            let bytes =
                rt.block_on(EdgeTtsClient::new(EdgeConfig::new(voice)?).synthesize(text))?;
            fs::write(out, bytes)?;
            return Ok(());
        }
        let binary = std::env::var_os("PIPER_BINARY")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("piper"));
        let model = std::env::var_os("PIPER_MODEL")
            .map(PathBuf::from)
            .unwrap_or_else(|| self.config.paths.piper_models_dir.join("en_US.onnx"));
        let mut c = PiperConfig::new(binary, model);
        c.chunk_chars = 5_000;
        piper::synthesize(&c, text, out, &self.cancel)
            .map(|_| ())
            .map_err(|e| WorkerError::Piper(e.to_string()))
    }
    fn emit(&self, event: ProgressEvent) {
        if let Some(sink) = &self.progress {
            sink(event)
        }
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
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                ' '
            } else {
                '_'
            }
        })
        .collect::<String>();
    s = s.split_whitespace().collect::<Vec<_>>().join("_");
    if s.is_empty() {
        "book".into()
    } else {
        s
    }
}
