//! Process-wide runtime registration and the single non-reentrant model transaction.
use super::piper_wav_validation::validate_wav;
use super::{PiperError, PiperRuntime, PiperRuntimeStatus};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock, RwLock};

pub(super) static MODEL_TRANSACTION: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub(super) fn cancellable_transaction(
    cancel: &super::CancellationToken,
) -> Result<std::sync::MutexGuard<'static, ()>, PiperError> {
    loop {
        if cancel.is_cancelled() {
            return Err(PiperError::Cancelled);
        }
        match MODEL_TRANSACTION.try_lock() {
            Ok(guard) => return Ok(guard),
            Err(std::sync::TryLockError::Poisoned(_)) => {
                return Err(PiperError::Synthesis("Piper runtime lock poisoned".into()))
            }
            Err(std::sync::TryLockError::WouldBlock) => {
                std::thread::sleep(std::time::Duration::from_millis(10))
            }
        }
    }
}

pub fn registered_runtime() -> Option<Arc<dyn PiperRuntime>> {
    runtime_slot().read().ok()?.clone()
}

/// Runtime adapter for platform glue and deterministic integration tests.
pub struct RegisteredPiperRuntime {
    synthesize_fn: Box<
        dyn Fn(&str, &Path, &(dyn Fn() -> bool + Sync)) -> Result<(), PiperError> + Send + Sync,
    >,
}

impl RegisteredPiperRuntime {
    pub fn new<F>(synthesize_fn: F) -> Self
    where
        F: Fn(&str, &Path, &(dyn Fn() -> bool + Sync)) -> Result<(), PiperError>
            + Send
            + Sync
            + 'static,
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

    fn synthesize(
        &self,
        text: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), PiperError> {
        (self.synthesize_fn)(text, output, cancelled)
    }

    fn shutdown(&self) {}
}

static RUNTIME: OnceLock<RwLock<Option<Arc<dyn PiperRuntime>>>> = OnceLock::new();

pub(super) fn runtime_slot() -> &'static RwLock<Option<Arc<dyn PiperRuntime>>> {
    RUNTIME.get_or_init(|| RwLock::new(None))
}

pub fn register_runtime(runtime: Arc<dyn PiperRuntime>) {
    let previous = {
        let mut slot = runtime_slot()
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let previous = slot.replace(runtime);
        // Explicit registration replaces the complete possibly poisoned state.
        runtime_slot().clear_poison();
        previous
    };
    // Provider destruction must not run under the process-wide registry lock.
    drop(previous);
}

pub fn piper_runtime_status() -> PiperRuntimeStatus {
    registered_runtime()
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
    let runtime = registered_runtime()
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
    let runtime = registered_runtime()
        .ok_or_else(|| PiperError::RuntimeUnavailable("no embedded runtime registered".into()))?;
    runtime.synthesize(text, output, &|| false)?;
    validate_wav(output)?;
    Ok(output.to_path_buf())
}

pub fn piper_runtime_shutdown() {
    let _transaction = MODEL_TRANSACTION
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(runtime) = registered_runtime() {
        runtime.shutdown();
    }
}

#[cfg(test)]
mod registry_recovery_tests {
    use super::*;

    #[test]
    fn poisoned_registry_rejects_calls_and_explicit_registration_recovers() {
        if std::env::var_os("CONVERTER_POISONED_REGISTRY_CHILD").is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "piper::piper_runtime_registry::registry_recovery_tests::poisoned_registry_rejects_calls_and_explicit_registration_recovers", "--nocapture"])
                .env("CONVERTER_POISONED_REGISTRY_CHILD", "1")
                .output().unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }
        register_runtime(Arc::new(RegisteredPiperRuntime::new(|_, _, _| Ok(()))));
        assert!(std::thread::spawn(|| {
            let _slot = runtime_slot().write().unwrap();
            panic!("poison the registration transaction");
        })
        .join()
        .is_err());
        assert!(registered_runtime().is_none());
        assert!(!piper_runtime_status().engine_ready);
        let output = Path::new("unused-poisoned-registry.wav");
        assert!(matches!(
            piper_synthesize("test", output),
            Err(PiperError::RuntimeUnavailable(_))
        ));
        assert!(!output.exists());
        piper_runtime_shutdown();
        register_runtime(Arc::new(RegisteredPiperRuntime::new(|_, _, _| Ok(()))));
        assert!(registered_runtime().is_some());
        assert!(piper_runtime_status().engine_ready);
        assert!(!runtime_slot().is_poisoned());
    }
}
