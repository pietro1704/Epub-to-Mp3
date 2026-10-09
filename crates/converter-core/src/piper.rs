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
pub struct CancellationToken(Arc<std::sync::atomic::AtomicBool>, Arc<tokio::sync::Notify>);
impl CancellationToken {
    pub fn cancel(&self) {
        self.0.store(true, std::sync::atomic::Ordering::Release);
        self.1.notify_waiters();
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(std::sync::atomic::Ordering::Acquire)
    }
    pub async fn cancelled(&self) {
        loop {
            let notified = self.1.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
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
    /// Legacy closure adapters may ignore init paths; never use them for explicit requests.
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
}

impl PreparedPiperModel {
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
        let prepared = Self {
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
        self.runtime.synthesize(text, output)?;
        validate_wav(output)
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
    runtime.synthesize(text, output)?;
    validate_wav(output)?;
    Ok(output.to_owned())
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
            let mut wav = vec![0u8; 144];
            wav[..4].copy_from_slice(b"RIFF");
            wav[8..12].copy_from_slice(b"WAVE");
            fs::write(output, wav).map_err(|error| PiperError::Io(error.to_string()))
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
