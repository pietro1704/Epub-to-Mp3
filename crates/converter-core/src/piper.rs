//! Embedded Piper runtime boundary.
//!
//! Shared Piper runtime boundary.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use std::sync::Arc;
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
pub struct CancellationToken {
    cancelled: Arc<std::sync::atomic::AtomicBool>,
    deadline: Option<std::time::Instant>,
}
impl CancellationToken {
    pub fn cancel(&self) {
        self.cancelled
            .store(true, std::sync::atomic::Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(std::sync::atomic::Ordering::Acquire) || self.timed_out()
    }
    pub(crate) fn with_timeout(&self, timeout: Duration) -> Self {
        let deadline = std::time::Instant::now().checked_add(timeout);
        Self {
            cancelled: Arc::clone(&self.cancelled),
            deadline: match (self.deadline, deadline) {
                (Some(existing), Some(requested)) => Some(existing.min(requested)),
                (existing, requested) => existing.or(requested),
            },
        }
    }
    pub(crate) fn timed_out(&self) -> bool {
        self.deadline
            .is_some_and(|deadline| std::time::Instant::now() >= deadline)
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
        validate_model_file_quality(&model, &config.config)?;
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

/// Adapters must not call this module's global runtime entry points from callbacks;
/// initialization and synthesis execute under one non-reentrant model transaction.
pub trait PiperRuntime: Send + Sync {
    fn status(&self) -> PiperRuntimeStatus;
    fn init(&self, model: &Path, config: &Path) -> Result<(), PiperError>;
    /// Cooperatively stop active work when cancellation or the chapter deadline fires.
    /// Implementations must return only after their synthesis resources are reclaimed.
    fn synthesize(
        &self,
        text: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), PiperError>;
    fn shutdown(&self);
    /// Closure adapters may ignore init paths and cannot honor explicit model selection.
    fn supports_explicit_model_paths(&self) -> bool {
        false
    }
}

mod piper_model_preparation;
mod piper_quality_policy;
pub(crate) use crate::model_catalog::validate_piper_quality as validate_model_quality;
pub(crate) use piper_quality_policy::validate_model_file_quality;
mod piper_runtime_registry;
mod piper_wav_validation;
pub use piper_model_preparation::{synthesize, synthesize_with_runtime, PreparedPiperModel};
pub use piper_runtime_registry::{
    piper_runtime_init, piper_runtime_shutdown, piper_runtime_status, piper_synthesize,
    register_runtime, registered_runtime, RegisteredPiperRuntime,
};
#[cfg(test)]
use piper_wav_validation::{publish_piper_audio, validate_wav};
#[cfg(test)]
use std::fs;

#[cfg(test)]
#[path = "piper/piper_contract_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "piper/piper_quality_tests.rs"]
mod quality_tests;

#[cfg(test)]
#[path = "piper/piper_cancellation_tests.rs"]
mod cancellation_tests;
