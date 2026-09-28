//! Native Piper process adapter.
//!
//! The adapter intentionally owns only process orchestration. Model discovery,
//! bounded chunking, cancellation, timeout handling, stderr classification, and
//! output validation live here so callers do not need Python or shell wrappers.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PiperConfig {
    pub binary: PathBuf,
    pub model: PathBuf,
    pub language_models: BTreeMap<String, PathBuf>,
    pub chunk_chars: usize,
    pub timeout: Duration,
}

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);
const TIMEOUT_PER_1K_CHARS: Duration = Duration::from_secs(15);
const TIMEOUT_PER_CHUNK: Duration = Duration::from_secs(120);

impl PiperConfig {
    pub fn new(binary: impl Into<PathBuf>, model: impl Into<PathBuf>) -> Self {
        Self {
            binary: binary.into(),
            model: model.into(),
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
    MissingBinary(PathBuf),
    MissingModel(PathBuf),
    InvalidChunkSize,
    EmptyOutput,
    Process { code: Option<i32>, stderr: String },
    Timeout,
    Cancelled,
    Io(String),
}

impl std::fmt::Display for PiperError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingBinary(path) => write!(f, "Piper binary not found: {}", path.display()),
            Self::MissingModel(path) => write!(f, "Piper model not found: {}", path.display()),
            Self::InvalidChunkSize => write!(f, "Piper chunk size must be greater than zero"),
            Self::EmptyOutput => write!(f, "Piper produced an empty or missing WAV output"),
            Self::Process { code, stderr } => write!(f, "Piper failed ({code:?}): {stderr}"),
            Self::Timeout => write!(f, "Piper process timed out"),
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

pub fn synthesize(
    config: &PiperConfig,
    text: &str,
    output: &Path,
    cancel: &CancellationToken,
) -> Result<PathBuf, PiperError> {
    if !config.binary.is_file() {
        return Err(PiperError::MissingBinary(config.binary.clone()));
    }
    let model = select_model(config, None)?;
    if cancel.is_cancelled() {
        return Err(PiperError::Cancelled);
    }
    if text.trim().is_empty() {
        return Err(PiperError::EmptyOutput);
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|e| PiperError::Io(e.to_string()))?;
    }
    let chunks = split_text(text, config.chunk_chars)?;
    let timeout = config
        .timeout
        .saturating_add(TIMEOUT_PER_1K_CHARS.saturating_mul((text.chars().count() / 1_000) as u32))
        .max(TIMEOUT_PER_CHUNK.saturating_mul(chunks.len() as u32));
    let mut child = Command::new(&config.binary)
        .args([
            "--model",
            model.to_str().unwrap_or_default(),
            "--output_file",
            output.to_str().unwrap_or_default(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| PiperError::Io(e.to_string()))?;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(text.as_bytes())
        .map_err(|e| PiperError::Io(e.to_string()))?;
    let started = Instant::now();
    loop {
        if cancel.is_cancelled() {
            let _ = child.kill();
            return Err(PiperError::Cancelled);
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            return Err(PiperError::Timeout);
        }
        match child
            .try_wait()
            .map_err(|e| PiperError::Io(e.to_string()))?
        {
            Some(status) => {
                let output_data = child
                    .wait_with_output()
                    .map_err(|e| PiperError::Io(e.to_string()))?;
                let stderr = String::from_utf8_lossy(&output_data.stderr)
                    .trim()
                    .to_owned();
                if !status.success() {
                    return Err(PiperError::Process {
                        code: status.code(),
                        stderr,
                    });
                }
                if !output.is_file() || fs::metadata(output).map(|m| m.len()).unwrap_or(0) == 0 {
                    return Err(PiperError::EmptyOutput);
                }
                return Ok(output.to_path_buf());
            }
            None => thread::sleep(Duration::from_millis(10)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn fake_executable_scaffolding_is_available() {
        let dir = tempfile_dir();
        let script = dir.join("piper-fake");
        let mut file = fs::File::create(&script).unwrap();
        writeln!(
            file,
            "#!/bin/sh\ncat >/dev/null\nprintf 'RIFFfake' > \"$4\""
        )
        .unwrap();
        drop(file);
        let mut perms = fs::metadata(&script).unwrap().permissions();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            perms.set_mode(0o755);
            fs::set_permissions(&script, perms).unwrap();
        }
        let model = dir.join("voice.onnx");
        fs::write(&model, b"model").unwrap();
        let out = dir.join("out.wav");
        let config = PiperConfig::new(script, model);
        assert!(synthesize(&config, "hello", &out, &CancellationToken::default()).is_ok());
    }

    #[test]
    fn timeout_budget_grows_for_multiple_chunks() {
        let dir = tempfile_dir();
        let script = dir.join("fast-piper");
        fs::write(&script, "#!/bin/sh\nprintf 'RIFFfake' > \"$4\"\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&script).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&script, permissions).unwrap();
        }
        let model = dir.join("voice.onnx");
        fs::write(&model, b"model").unwrap();
        let output = dir.join("out.wav");
        let mut config = PiperConfig::new(script, model);
        config.chunk_chars = 5_000;
        config.timeout = Duration::from_secs(1);
        assert!(synthesize(&config, "hello", &output, &CancellationToken::default()).is_ok());
    }

    fn tempfile_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!("piper-adapter-{}", std::process::id()));
        let _ = fs::create_dir_all(&path);
        path
    }
}
