//! Embedded Piper runtime boundary.
//!
//! Shared Piper runtime boundary.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PiperConfig {
    pub model: PathBuf,
    pub config: PathBuf,
    pub language_models: BTreeMap<String, PathBuf>,
    pub chunk_chars: usize,
    pub timeout: Duration,
}

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);

impl PiperConfig {
    pub fn new(model: impl Into<PathBuf>, config: impl Into<PathBuf>) -> Self {
        Self {
            model: model.into(),
            config: config.into(),
            language_models: BTreeMap::new(),
            chunk_chars: 5_000,
            timeout: DEFAULT_TIMEOUT,
        }
    }

    pub fn model_for_language(&self, language: Option<&str>) -> &Path {
        let code = language
            .unwrap_or_default()
            .split('-')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        self.language_models
            .get(&code)
            .map(PathBuf::as_path)
            .unwrap_or(self.model.as_path())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PiperError {
    RuntimeUnavailable(String),
    IncompatibleAbi(String),
    MissingModel(PathBuf),
    MissingConfig(PathBuf),
    InvalidChunkSize,
    EmptyOutput,
    Synthesis(String),
    InvalidWav(String),
    Timeout,
    Cancelled,
    Io(String),
}

impl std::fmt::Display for PiperError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RuntimeUnavailable(message) => {
                write!(f, "Piper embedded runtime unavailable: {message}")
            }
            Self::IncompatibleAbi(message) => {
                write!(f, "Piper embedded runtime ABI incompatible: {message}")
            }
            Self::MissingModel(path) => write!(f, "Piper model not found: {}", path.display()),
            Self::MissingConfig(path) => {
                write!(f, "Piper voice config not found: {}", path.display())
            }
            Self::InvalidChunkSize => write!(f, "Piper chunk size must be greater than zero"),
            Self::EmptyOutput => write!(f, "Piper produced an empty or missing WAV output"),
            Self::Synthesis(message) => write!(f, "Piper synthesis failed: {message}"),
            Self::InvalidWav(message) => write!(f, "Piper produced invalid WAV: {message}"),
            Self::Timeout => write!(f, "Piper synthesis timed out"),
            Self::Cancelled => write!(f, "Piper synthesis cancelled"),
            Self::Io(message) => f.write_str(message),
        }
    }
}
impl std::error::Error for PiperError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StderrClass {
    None,
    Warning,
    MissingModel,
    MissingPhoneme,
    Fatal,
}

pub fn classify_stderr(stderr: &str) -> StderrClass {
    let lower = stderr.to_ascii_lowercase();
    if lower.trim().is_empty() {
        StderrClass::None
    } else if lower.contains("no such file")
        || lower.contains("model") && lower.contains("not found")
    {
        StderrClass::MissingModel
    } else if lower.contains("phoneme") || lower.contains("phonemization") {
        StderrClass::MissingPhoneme
    } else if lower.contains("error") || lower.contains("fatal") || lower.contains("failed") {
        StderrClass::Fatal
    } else {
        StderrClass::Warning
    }
}

#[derive(Debug, Clone, Default)]
pub struct CancellationToken(Arc<std::sync::atomic::AtomicBool>);
impl CancellationToken {
    pub fn cancel(&self) {
        self.0.store(true, std::sync::atomic::Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(std::sync::atomic::Ordering::Acquire)
    }
}

pub fn split_text(text: &str, max_chars: usize) -> Result<Vec<String>, PiperError> {
    if max_chars == 0 {
        return Err(PiperError::InvalidChunkSize);
    }
    if text.chars().count() <= max_chars {
        return Ok(vec![text.to_owned()]);
    }
    let mut result = Vec::new();
    let mut remaining = text.trim();
    while !remaining.is_empty() {
        let boundary = remaining
            .char_indices()
            .take(max_chars + 1)
            .last()
            .map(|(i, _)| i)
            .unwrap_or(remaining.len());
        let candidate = &remaining[..boundary];
        let split = candidate
            .rfind(['.', '!', '?', '\n'])
            .map(|i| i + candidate[i..].chars().next().unwrap().len_utf8())
            .or_else(|| candidate.rfind(' ').map(|i| i + 1))
            .filter(|i| *i > boundary / 2)
            .unwrap_or(boundary);
        let chunk = remaining[..split].trim();
        if !chunk.is_empty() {
            result.push(chunk.to_owned());
        }
        remaining = remaining[split..].trim_start();
    }
    Ok(result)
}

pub fn select_model(config: &PiperConfig, language: Option<&str>) -> Result<PathBuf, PiperError> {
    let model = config.model_for_language(language).to_path_buf();
    if model.is_file() {
        Ok(model)
    } else {
        Err(PiperError::MissingModel(model))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PiperRuntimeStatus {
    pub runtime_loaded: bool,
    pub model_available: bool,
    pub abi_compatible: bool,
    pub engine_ready: bool,
}

pub trait PiperRuntime: Send + Sync {
    fn status(&self) -> PiperRuntimeStatus;
    fn init(&self, model: &Path, config: &Path) -> Result<(), PiperError>;
    fn synthesize(&self, text: &str, output: &Path) -> Result<(), PiperError>;
    fn shutdown(&self);
}

static RUNTIME: OnceLock<RwLock<Option<Arc<dyn PiperRuntime>>>> = OnceLock::new();

fn runtime_slot() -> &'static RwLock<Option<Arc<dyn PiperRuntime>>> {
    RUNTIME.get_or_init(|| RwLock::new(None))
}

pub fn register_runtime(runtime: Arc<dyn PiperRuntime>) {
    *runtime_slot().write().expect("Piper runtime lock poisoned") = Some(runtime);
}

pub fn piper_runtime_status() -> PiperRuntimeStatus {
    runtime_slot()
        .read()
        .expect("Piper runtime lock poisoned")
        .as_ref()
        .map(|runtime| runtime.status())
        .unwrap_or(PiperRuntimeStatus {
            runtime_loaded: false,
            model_available: false,
            abi_compatible: false,
            engine_ready: false,
        })
}

pub fn piper_runtime_init(model: &Path, config: &Path) -> Result<(), PiperError> {
    if !model.is_file() {
        return Err(PiperError::MissingModel(model.to_path_buf()));
    }
    if !config.is_file() {
        return Err(PiperError::MissingConfig(config.to_path_buf()));
    }
    let runtime = runtime_slot()
        .read()
        .expect("Piper runtime lock poisoned")
        .clone()
        .ok_or_else(|| PiperError::RuntimeUnavailable("no embedded runtime registered".into()))?;
    runtime.init(model, config)
}

pub fn piper_synthesize(text: &str, output: &Path) -> Result<PathBuf, PiperError> {
    if text.trim().is_empty() {
        return Err(PiperError::EmptyOutput);
    }
    let runtime = runtime_slot()
        .read()
        .expect("Piper runtime lock poisoned")
        .clone()
        .ok_or_else(|| PiperError::RuntimeUnavailable("no embedded runtime registered".into()))?;
    runtime.synthesize(text, output)?;
    validate_wav(output)?;
    Ok(output.to_path_buf())
}

pub fn piper_runtime_shutdown() {
    if let Some(runtime) = runtime_slot()
        .read()
        .expect("Piper runtime lock poisoned")
        .as_ref()
        .cloned()
    {
        runtime.shutdown();
    }
}

fn validate_wav(path: &Path) -> Result<(), PiperError> {
    let data = fs::read(path).map_err(|error| PiperError::InvalidWav(error.to_string()))?;
    if data.len() < 44 || &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return Err(PiperError::InvalidWav("missing RIFF/WAVE header".into()));
    }
    if data.len() <= 44 {
        return Err(PiperError::InvalidWav("audio payload is empty".into()));
    }
    Ok(())
}
pub fn synthesize(
    config: &PiperConfig,
    text: &str,
    output: &Path,
    cancel: &CancellationToken,
) -> Result<PathBuf, PiperError> {
    if cancel.is_cancelled() {
        return Err(PiperError::Cancelled);
    }
    let model = select_model(config, None)?;
    if text.trim().is_empty() {
        return Err(PiperError::EmptyOutput);
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|e| PiperError::Io(e.to_string()))?;
    }
    if runtime_slot()
        .read()
        .expect("Piper runtime lock poisoned")
        .is_some()
    {
        piper_runtime_init(&model, &config.config)?;
        return piper_synthesize(text, output);
    }
    let binary = std::env::var_os("PIPER_BINARY")
        .ok_or_else(|| PiperError::RuntimeUnavailable("PIPER_BINARY is not configured".into()))?;
    let mut child = Command::new(binary)
        .args([
            "-m",
            &model.to_string_lossy(),
            "-f",
            &output.to_string_lossy(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| PiperError::RuntimeUnavailable(error.to_string()))?;
    use std::io::Write;
    child
        .stdin
        .take()
        .ok_or_else(|| PiperError::Synthesis("Piper stdin unavailable".into()))?
        .write_all(text.as_bytes())
        .map_err(|error| PiperError::Io(error.to_string()))?;
    let result = child
        .wait_with_output()
        .map_err(|error| PiperError::Io(error.to_string()))?;
    if !result.status.success() {
        return Err(PiperError::Synthesis(
            String::from_utf8_lossy(&result.stderr).trim().to_owned(),
        ));
    }
    validate_wav(output)?;
    Ok(output.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_runtime_is_reported_without_external_process_fallback() {
        let dir = tempfile_dir();
        let model = dir.join("voice.onnx");
        let config_path = model.with_extension("json");
        fs::write(&model, b"model").unwrap();
        fs::write(&config_path, b"{}").unwrap();
        let output = dir.join("out.wav");
        let config = PiperConfig::new(model, config_path);
        let result = synthesize(&config, "hello", &output, &CancellationToken::default());
        assert!(result.is_err());
    }

    fn tempfile_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!("piper-adapter-{}", std::process::id()));
        let _ = fs::create_dir_all(&path);
        path
    }
}
