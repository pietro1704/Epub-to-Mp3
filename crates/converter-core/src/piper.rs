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

/// Adapters must not call this module's global runtime entry points from callbacks;
/// initialization and synthesis execute under one non-reentrant model transaction.
pub trait PiperRuntime: Send + Sync {
    fn status(&self) -> PiperRuntimeStatus;
    fn init(&self, model: &Path, config: &Path) -> Result<(), PiperError>;
    fn synthesize(&self, text: &str, output: &Path) -> Result<(), PiperError>;
    fn shutdown(&self);
    /// Closure adapters may ignore init paths and cannot honor explicit model selection.
    fn supports_explicit_model_paths(&self) -> bool {
        false
    }
}

static MODEL_TRANSACTION: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Prepared paths and the exact runtime that verified them, pinned per request.
pub struct PreparedPiperModel {
    model: PathBuf,
    config: PathBuf,
    runtime: Arc<dyn PiperRuntime>,
    cache_identity: String,
}

impl PreparedPiperModel {
    pub(crate) fn cache_identity(&self) -> String {
        self.cache_identity.clone()
    }

    pub fn prepare(
        root: &Path,
        model_id: &str,
        model_path: &Path,
        config_path: &Path,
        runtime: Arc<dyn PiperRuntime>,
    ) -> Result<Self, PiperError> {
        use std::path::Component;
        let relative = |path: &Path| {
            !path.as_os_str().is_empty()
                && path
                    .components()
                    .all(|part| matches!(part, Component::Normal(_)))
        };
        if !root.is_absolute()
            || model_id.is_empty()
            || Path::new(model_id).components().count() != 1
            || !relative(Path::new(model_id))
            || !relative(model_path)
            || !relative(config_path)
        {
            return Err(PiperError::Synthesis(
                "invalid scoped Piper model paths".into(),
            ));
        }
        let root = root
            .canonicalize()
            .map_err(|error| PiperError::Io(format!("models_root: {error}")))?;
        let namespace = root
            .join(model_id)
            .canonicalize()
            .map_err(|error| PiperError::Io(format!("model_id: {error}")))?;
        if namespace == root || !namespace.starts_with(&root) || !namespace.is_dir() {
            return Err(PiperError::Synthesis(
                "Piper model namespace escapes models_root".into(),
            ));
        }
        let model = namespace
            .join(model_path)
            .canonicalize()
            .map_err(|_| PiperError::MissingModel(namespace.join(model_path)))?;
        let config = namespace
            .join(config_path)
            .canonicalize()
            .map_err(|_| PiperError::MissingConfig(namespace.join(config_path)))?;
        if !model.starts_with(&namespace) || !config.starts_with(&namespace) {
            return Err(PiperError::Synthesis(
                "Piper model/config escapes installed namespace".into(),
            ));
        }
        validate_model_files(&model, &config)?;
        if !runtime.supports_explicit_model_paths() {
            return Err(PiperError::RuntimeUnavailable(
                "runtime does not support per-request model paths".into(),
            ));
        }
        // Hash once during explicit preparation, not once for every chapter.
        let model_hash =
            crate::cache::sha256_file(&model).map_err(|error| PiperError::Io(error.to_string()))?;
        let config_hash = crate::cache::sha256_file(&config)
            .map_err(|error| PiperError::Io(error.to_string()))?;
        let cache_identity = format!("piper:{model:?}:{config:?}:{model_hash}:{config_hash}");
        let prepared = Self {
            cache_identity,
            model,
            config,
            runtime,
        };
        let _transaction = MODEL_TRANSACTION
            .lock()
            .map_err(|_| PiperError::Synthesis("Piper runtime lock poisoned".into()))?;
        prepared.initialize()?;
        Ok(prepared)
    }

    fn initialize(&self) -> Result<(), PiperError> {
        validate_model_files(&self.model, &self.config)?;
        self.runtime.init(&self.model, &self.config)?;
        let status = self.runtime.status();
        if !status.runtime_loaded
            || !status.abi_compatible
            || !status.model_available
            || !status.engine_ready
        {
            return Err(PiperError::RuntimeUnavailable(
                "requested Piper model failed runtime readiness after initialization".into(),
            ));
        }
        Ok(())
    }

    pub fn synthesize(
        &self,
        text: &str,
        output: &Path,
        cancel: &CancellationToken,
    ) -> Result<(), PiperError> {
        let _transaction = MODEL_TRANSACTION
            .lock()
            .map_err(|_| PiperError::Synthesis("Piper runtime lock poisoned".into()))?;
        if cancel.is_cancelled() {
            return Err(PiperError::Cancelled);
        }
        if text.trim().is_empty() {
            return Err(PiperError::EmptyOutput);
        }
        self.initialize()?;
        let parent = output
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent).map_err(|error| PiperError::Io(error.to_string()))?;
        let staging = tempfile::Builder::new()
            .prefix(".piper-audio-")
            .tempdir_in(parent)
            .map_err(|error| PiperError::Io(error.to_string()))?;
        let wav = staging.path().join("speech.wav");
        self.runtime.synthesize(text, &wav)?;
        if cancel.is_cancelled() {
            return Err(PiperError::Cancelled);
        }
        publish_piper_audio(&wav, output).map(|_| ())
    }
}

fn validate_model_files(model: &Path, config: &Path) -> Result<(), PiperError> {
    if !model.is_file() {
        return Err(PiperError::MissingModel(model.to_owned()));
    }
    if !config.is_file() {
        return Err(PiperError::MissingConfig(config.to_owned()));
    }
    fs::File::open(model)
        .map_err(|error| PiperError::Io(format!("model is unreadable: {error}")))?;
    fs::File::open(config)
        .map_err(|error| PiperError::Io(format!("model config is unreadable: {error}")))?;
    Ok(())
}

pub fn registered_runtime() -> Option<Arc<dyn PiperRuntime>> {
    runtime_slot().read().ok()?.clone()
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
    let _transaction = MODEL_TRANSACTION
        .lock()
        .map_err(|_| PiperError::Synthesis("Piper runtime lock poisoned".into()))?;
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
    let _transaction = MODEL_TRANSACTION
        .lock()
        .map_err(|_| PiperError::Synthesis("Piper runtime lock poisoned".into()))?;
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
    let _transaction = MODEL_TRANSACTION
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
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
    let _transaction = MODEL_TRANSACTION
        .lock()
        .map_err(|_| PiperError::Synthesis("Piper runtime lock poisoned".into()))?;
    validate_model_files(&model, &config.config)?;
    let runtime = registered_runtime()
        .ok_or_else(|| PiperError::RuntimeUnavailable("no embedded runtime registered".into()))?;
    runtime.init(&model, &config.config)?;
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let staging = tempfile::Builder::new()
        .prefix(".piper-audio-")
        .tempdir_in(parent)
        .map_err(|error| PiperError::Io(error.to_string()))?;
    let wav = staging.path().join("speech.wav");
    runtime.synthesize(text, &wav)?;
    validate_wav(&wav)?;
    if cancel.is_cancelled() {
        return Err(PiperError::Cancelled);
    }
    publish_piper_audio(&wav, output)
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
    let sample_rate = u32::from_le_bytes(data[24..28].try_into().expect("validated WAV header"));
    let channels = u16::from_le_bytes(data[22..24].try_into().expect("validated WAV header"));
    let bits_per_sample =
        u16::from_le_bytes(data[34..36].try_into().expect("validated WAV header"));
    let format = u16::from_le_bytes(data[20..22].try_into().expect("validated WAV header"));
    if format != 1 || bits_per_sample != 16 || channels != 1 || &data[36..40] != b"data" {
        return Err(PiperError::InvalidWav(
            "expected mono 16-bit PCM from the embedded runtime".into(),
        ));
    }
    let payload_len =
        u32::from_le_bytes(data[40..44].try_into().expect("validated WAV header")) as usize;
    let payload = data
        .get(44..44usize.saturating_add(payload_len))
        .ok_or_else(|| PiperError::InvalidWav("PCM payload is truncated".into()))?;
    if payload.is_empty() || payload.len() % 2 != 0 || sample_rate == 0 {
        return Err(PiperError::InvalidWav(
            "invalid PCM audio dimensions".into(),
        ));
    }

    let mut encoder = rusty_mp3::Mp3Encoder::new(rusty_mp3::Mp3EncoderConfig {
        bitrate_kbps: 96,
        vbr_quality: None,
    });
    encoder
        .push_pcm_s16le(payload, channels, sample_rate)
        .map_err(|error| PiperError::Synthesis(format!("MP3 encoding failed: {error}")))?;
    encoder.finish();
    let mut encoded = Vec::new();
    while let Ok(packet) = encoder.next_packet() {
        encoded.extend_from_slice(&packet);
    }
    let mut decoder = rusty_mp3::Mp3Decoder::new();
    decoder.push(&encoded);
    decoder.flush();
    let mut decoded_samples = 0usize;
    while let Ok(frame) = decoder.next_frame() {
        decoded_samples += frame.samples.len();
    }
    if decoded_samples == 0 {
        return Err(PiperError::Synthesis(
            "MP3 encoder produced no playable frames".into(),
        ));
    }

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

    struct ScopedRuntime {
        active: std::sync::Mutex<Option<(PathBuf, PathBuf)>>,
        calls: std::sync::Mutex<Vec<(PathBuf, PathBuf, String)>>,
        ready: bool,
        reject_init: bool,
    }
    impl PiperRuntime for ScopedRuntime {
        fn supports_explicit_model_paths(&self) -> bool {
            true
        }
        fn status(&self) -> PiperRuntimeStatus {
            PiperRuntimeStatus {
                runtime_loaded: true,
                model_available: self.ready,
                abi_compatible: true,
                engine_ready: self.ready,
            }
        }
        fn init(&self, model: &Path, config: &Path) -> Result<(), PiperError> {
            if self.reject_init {
                return Err(PiperError::Synthesis(
                    "controlled initialization failure".into(),
                ));
            }
            *self.active.lock().unwrap() = Some((model.to_owned(), config.to_owned()));
            Ok(())
        }
        fn synthesize(&self, text: &str, output: &Path) -> Result<(), PiperError> {
            // Give another request an opportunity to initialize this shared runtime.
            std::thread::sleep(std::time::Duration::from_millis(10));
            let (model, config) = self.active.lock().unwrap().clone().unwrap();
            self.calls
                .lock()
                .unwrap()
                .push((model, config, text.into()));
            write_test_wav(output);
            Ok(())
        }
        fn shutdown(&self) {}
    }
    fn scoped_runtime(ready: bool, reject_init: bool) -> Arc<ScopedRuntime> {
        Arc::new(ScopedRuntime {
            active: std::sync::Mutex::new(None),
            calls: std::sync::Mutex::new(Vec::new()),
            ready,
            reject_init,
        })
    }
    fn installed_fixture(root: &Path, id: &str) {
        fs::create_dir(root.join(id)).unwrap();
        fs::write(root.join(id).join("voice.onnx"), b"synthetic model").unwrap();
        fs::write(root.join(id).join("voice.config.json"), b"{}").unwrap();
    }

    #[test]
    fn explicit_model_preflight_requires_actual_initialization_and_ready_runtime() {
        let fixture = tempfile::tempdir().unwrap();
        installed_fixture(fixture.path(), "selected");
        for runtime in [scoped_runtime(false, false), scoped_runtime(true, true)] {
            assert!(PreparedPiperModel::prepare(
                fixture.path(),
                "selected",
                Path::new("voice.onnx"),
                Path::new("voice.config.json"),
                runtime
            )
            .is_err());
        }
        let ignored_paths = Arc::new(RegisteredPiperRuntime::new(|_, _| Ok(())));
        assert!(PreparedPiperModel::prepare(
            fixture.path(),
            "selected",
            Path::new("voice.onnx"),
            Path::new("voice.config.json"),
            ignored_paths
        )
        .is_err());
        assert_eq!(
            fs::read(fixture.path().join("selected/voice.onnx")).unwrap(),
            b"synthetic model"
        );
    }

    #[test]
    fn explicit_models_are_pinned_and_init_plus_synthesis_is_atomic_between_requests() {
        let fixture = tempfile::tempdir().unwrap();
        for id in ["one", "two"] {
            installed_fixture(fixture.path(), id);
        }
        let runtime = scoped_runtime(true, false);
        let mut requests = Vec::new();
        for id in ["one", "two"] {
            let prepared = PreparedPiperModel::prepare(
                fixture.path(),
                id,
                Path::new("voice.onnx"),
                Path::new("voice.config.json"),
                runtime.clone(),
            )
            .unwrap();
            requests.push((id, prepared, fixture.path().join(format!("{id}.wav"))));
        }
        std::thread::scope(|scope| {
            for (id, prepared, output) in requests {
                scope.spawn(move || {
                    prepared
                        .synthesize(id, &output, &CancellationToken::default())
                        .unwrap()
                });
            }
        });
        let calls = runtime.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        for (model, config, text) in calls.iter() {
            assert_eq!(
                model
                    .parent()
                    .unwrap()
                    .file_name()
                    .unwrap()
                    .to_str()
                    .unwrap(),
                text
            );
            assert_eq!(config, &model.with_file_name("voice.config.json"));
        }
    }

    #[test]
    fn explicit_model_paths_reject_traversal_missing_files_and_namespace_escape() {
        let fixture = tempfile::tempdir().unwrap();
        installed_fixture(fixture.path(), "selected");
        for (id, model, config) in [
            ("../selected", "voice.onnx", "voice.config.json"),
            ("selected", "../voice.onnx", "voice.config.json"),
            ("selected", "/outside.onnx", "voice.config.json"),
            ("selected", "missing.onnx", "voice.config.json"),
            ("selected", "voice.onnx", "missing.json"),
        ] {
            assert!(PreparedPiperModel::prepare(
                fixture.path(),
                id,
                Path::new(model),
                Path::new(config),
                scoped_runtime(true, false)
            )
            .is_err());
        }
        #[cfg(unix)]
        {
            let outside = tempfile::tempdir().unwrap();
            fs::write(outside.path().join("external.onnx"), b"preserve").unwrap();
            std::os::unix::fs::symlink(
                outside.path().join("external.onnx"),
                fixture.path().join("selected/escape.onnx"),
            )
            .unwrap();
            assert!(PreparedPiperModel::prepare(
                fixture.path(),
                "selected",
                Path::new("escape.onnx"),
                Path::new("voice.config.json"),
                scoped_runtime(true, false)
            )
            .is_err());
            assert_eq!(
                fs::read(outside.path().join("external.onnx")).unwrap(),
                b"preserve"
            );
        }
    }

    #[test]
    fn cancelled_explicit_model_preserves_existing_audio_and_model_identity_is_distinct() {
        let fixture = tempfile::tempdir().unwrap();
        for id in ["one", "two"] {
            installed_fixture(fixture.path(), id);
        }
        let runtime = scoped_runtime(true, false);
        let prepare = |id| {
            PreparedPiperModel::prepare(
                fixture.path(),
                id,
                Path::new("voice.onnx"),
                Path::new("voice.config.json"),
                runtime.clone(),
            )
            .unwrap()
        };
        let first = prepare("one");
        let second = prepare("two");
        assert_ne!(first.cache_identity(), second.cache_identity());
        let output = fixture.path().join("previous.mp3");
        fs::write(&output, b"previous audio").unwrap();
        let cancel = CancellationToken::default();
        cancel.cancel();
        assert_eq!(
            first.synthesize("cancelled", &output, &cancel),
            Err(PiperError::Cancelled)
        );
        assert_eq!(fs::read(output).unwrap(), b"previous audio");
        assert!(runtime.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn replacing_model_or_config_at_same_paths_changes_prepared_cache_identity() {
        let fixture = tempfile::tempdir().unwrap();
        installed_fixture(fixture.path(), "selected");
        let runtime = scoped_runtime(true, false);
        let prepare = || {
            PreparedPiperModel::prepare(
                fixture.path(),
                "selected",
                Path::new("voice.onnx"),
                Path::new("voice.config.json"),
                runtime.clone(),
            )
            .unwrap()
        };
        let original = prepare();
        fs::write(
            fixture.path().join("selected/voice.onnx"),
            b"replacement model",
        )
        .unwrap();
        let changed_model = prepare();
        assert_ne!(original.cache_identity(), changed_model.cache_identity());
        fs::write(
            fixture.path().join("selected/voice.config.json"),
            b"{\"new\":true}",
        )
        .unwrap();
        let changed_config = prepare();
        assert_ne!(
            changed_model.cache_identity(),
            changed_config.cache_identity()
        );
    }

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
