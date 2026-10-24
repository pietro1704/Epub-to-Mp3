//! Process-wide runtime registration and the single non-reentrant model transaction.
use super::piper_wav_validation::validate_wav;
use super::{PiperError, PiperRuntime, PiperRuntimeStatus};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock, RwLock};

pub(super) static MODEL_TRANSACTION: std::sync::Mutex<()> = std::sync::Mutex::new(());

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

pub(super) fn runtime_slot() -> &'static RwLock<Option<Arc<dyn PiperRuntime>>> {
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
    super::validate_model_file_quality(model, config)?;
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
