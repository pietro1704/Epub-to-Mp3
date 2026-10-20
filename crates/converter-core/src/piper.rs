//! Embedded Piper runtime boundary.
//!
//! Shared Piper runtime boundary.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

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

/// Runtime adapter for platform glue and deterministic integration tests.
pub struct RegisteredPiperRuntime {
    synthesize_fn: Box<dyn Fn(&str, &Path) -> Result<(), PiperError> + Send + Sync>,
}

impl RegisteredPiperRuntime {
    pub fn new<F>(synthesize_fn: F) -> Self
    where
        F: Fn(&str, &Path) -> Result<(), PiperError> + Send + Sync + 'static,
    {
        Self {
            synthesize_fn: Box::new(synthesize_fn),
        }
    }
}

impl PiperRuntime for RegisteredPiperRuntime {
    fn status(&self) -> PiperRuntimeStatus {
        PiperRuntimeStatus {
            runtime_loaded: true,
            model_available: true,
            abi_compatible: true,
            engine_ready: true,
        }
    }

    fn init(&self, _model: &Path, _config: &Path) -> Result<(), PiperError> {
        Ok(())
    }

    fn synthesize(&self, text: &str, output: &Path) -> Result<(), PiperError> {
        (self.synthesize_fn)(text, output)
    }

    fn shutdown(&self) {}
}

static SYNTHESIS_GATE: std::sync::Mutex<()> = std::sync::Mutex::new(());
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
/// Synthesize WAV audio, encoding MP3 when the destination has an MP3 extension.
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
        .is_none()
    {
        return Err(PiperError::RuntimeUnavailable(
            "embedded Piper runtime is not registered".into(),
        ));
    }
    let _gate = SYNTHESIS_GATE
        .lock()
        .map_err(|_| PiperError::RuntimeUnavailable("Piper synthesis lock poisoned".into()))?;
    piper_runtime_init(&model, &config.config)?;
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let staging = tempfile::Builder::new()
        .prefix(".piper-audio-")
        .tempdir_in(parent)
        .map_err(|error| PiperError::Io(error.to_string()))?;
    let wav = staging.path().join("speech.wav");
    let path = piper_synthesize(text, &wav)?;
    if cancel.is_cancelled() {
        return Err(PiperError::Cancelled);
    }
    publish_piper_audio(&path, output)
}

fn publish_piper_audio(wav: &Path, output: &Path) -> Result<PathBuf, PiperError> {
    validate_wav(wav)?;
    if output
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("mp3"))
    {
        encode_piper_mp3(wav, output)?;
    } else if wav != output {
        fs::rename(wav, output).map_err(|error| PiperError::Io(error.to_string()))?;
    }
    Ok(output.to_path_buf())
}

fn encode_piper_mp3(wav: &Path, output: &Path) -> Result<(), PiperError> {
    let data = fs::read(wav).map_err(|error| PiperError::Io(error.to_string()))?;
    let encoded =
        crate::pcm::encode_wav_mp3_preserving_rate(&data).map_err(PiperError::InvalidWav)?;
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|error| PiperError::Io(error.to_string()))?;
    let staging = tempfile::Builder::new()
        .prefix(".piper-mp3-")
        .tempdir_in(parent)
        .map_err(|error| PiperError::Io(error.to_string()))?;
    let staged = staging.path().join("speech.mp3");
    fs::write(&staged, encoded).map_err(|error| PiperError::Io(error.to_string()))?;
    let file = fs::File::open(&staged).map_err(|error| PiperError::Io(error.to_string()))?;
    file.sync_all()
        .map_err(|error| PiperError::Io(error.to_string()))?;
    fs::rename(staged, output).map_err(|error| PiperError::Io(error.to_string()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_test_wav(path: &Path) {
        let sample_rate = 22_050_u32;
        let sample_count = sample_rate / 4;
        let data_length = sample_count * 2;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data_length).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&sample_rate.to_le_bytes());
        bytes.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&16_u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_length.to_le_bytes());
        for index in 0..sample_count {
            let sample = ((index as f32 * 440.0 * std::f32::consts::TAU / sample_rate as f32).sin()
                * i16::MAX as f32
                * 0.4) as i16;
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn mp3_destination_contains_decodable_audio_without_external_tools() {
        let root = tempfile::Builder::new()
            .prefix("piper codec's fixture ")
            .tempdir()
            .unwrap();
        let wav = root.path().join("native.wav");
        let output = root.path().join("chapter.mp3");
        write_test_wav(&wav);
        publish_piper_audio(&wav, &output).unwrap();
        let encoded = fs::read(&output).unwrap();
        let mut decoder = rusty_mp3::Mp3Decoder::new();
        decoder.push(&encoded);
        decoder.flush();
        let mut decoded_samples = Vec::new();
        while let Ok(decoded) = decoder.next_frame() {
            decoded_samples.extend(decoded.samples);
        }
        assert!(!decoded_samples.is_empty());
        assert!(decoded_samples.iter().any(|sample| sample.abs() > 0.01));

        if std::process::Command::new("ffprobe")
            .arg("-version")
            .output()
            .is_ok()
        {
            let probe = std::process::Command::new("ffprobe")
                .args([
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=codec_name,sample_rate,channels",
                    "-of",
                    "csv=p=0",
                ])
                .arg(&output)
                .output()
                .expect("ffprobe availability was checked");
            assert!(probe.status.success());
            assert_eq!(String::from_utf8_lossy(&probe.stdout).trim(), "mp3,22050,1");
        }
        if std::process::Command::new("ffmpeg")
            .arg("-version")
            .output()
            .is_ok()
        {
            let decode = std::process::Command::new("ffmpeg")
                .args(["-v", "error", "-i"])
                .arg(&output)
                .args(["-f", "null", "-"])
                .output()
                .expect("ffmpeg availability was checked");
            assert!(
                decode.status.success(),
                "ffmpeg could not decode MP3: {}",
                String::from_utf8_lossy(&decode.stderr)
            );
        }
    }

    #[test]
    fn wav_destination_preserves_the_native_payload() {
        let root = tempfile::tempdir().unwrap();
        let wav = root.path().join("native.wav");
        let output = root.path().join("chapter.wav");
        write_test_wav(&wav);
        let expected = fs::read(&wav).unwrap();
        assert_eq!(publish_piper_audio(&wav, &output).unwrap(), output);
        assert_eq!(fs::read(&output).unwrap(), expected);
        validate_wav(&output).unwrap();
    }

    #[test]
    fn invalid_wave_does_not_replace_previous_audio() {
        let root = tempfile::tempdir().unwrap();
        let wav = root.path().join("invalid.wav");
        let output = root.path().join("chapter.mp3");
        fs::write(&wav, b"invalid wave input").unwrap();
        fs::write(&output, b"previous audio").unwrap();
        assert!(matches!(
            publish_piper_audio(&wav, &output),
            Err(PiperError::InvalidWav(_))
        ));
        assert_eq!(fs::read(output).unwrap(), b"previous audio");
    }

    #[test]
    fn invalid_mp3_sample_rate_preserves_previous_audio() {
        let root = tempfile::tempdir().unwrap();
        let wav = root.path().join("native.wav");
        let output = root.path().join("chapter.mp3");
        write_test_wav(&wav);
        let mut bytes = fs::read(&wav).unwrap();
        bytes[24..28].copy_from_slice(&12_345_u32.to_le_bytes());
        fs::write(&wav, bytes).unwrap();
        fs::write(&output, b"previous audio").unwrap();
        assert!(publish_piper_audio(&wav, &output).is_err());
        assert_eq!(fs::read(output).unwrap(), b"previous audio");
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 2);
    }

    #[test]
    fn cancellation_token_can_be_shared_with_active_worker() {
        let token = CancellationToken::default();
        let worker_token = token.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(10));
            worker_token.cancel();
        })
        .join()
        .unwrap();
        assert!(token.is_cancelled());
    }

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
