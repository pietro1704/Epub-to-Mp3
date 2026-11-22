//! Request-scoped model identity, readiness and atomic synthesis preparation.
use super::piper_runtime_registry::{registered_runtime, MODEL_TRANSACTION};
use super::piper_wav_validation::{publish_piper_audio_cancellable, validate_wav};
use super::{select_model, CancellationToken, PiperConfig, PiperError, PiperRuntime};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Prepared paths and the exact runtime that verified them, pinned per request.
pub struct PreparedPiperModel {
    model: PathBuf,
    config: PathBuf,
    runtime: Arc<dyn PiperRuntime>,
    explicit_low_revision: Option<String>,
    _model_usage: crate::model_store::model_usage::ModelUsageLease,
}

impl PreparedPiperModel {
    pub fn prepare(
        root: &Path,
        model_id: &str,
        model_path: &Path,
        config_path: &Path,
        runtime: Arc<dyn PiperRuntime>,
    ) -> Result<Self, PiperError> {
        Self::prepare_with_revision(root, model_id, model_path, config_path, runtime, None)
    }

    /// Load an explicitly requested catalog model using its verified artifacts.
    pub fn prepare_explicit_low(
        root: &Path,
        model_id: &str,
        revision: &str,
        runtime: Arc<dyn PiperRuntime>,
    ) -> Result<Self, PiperError> {
        let descriptor = crate::model_catalog::model_by_id(model_id)
            .filter(|model| {
                model.engine == "piper"
                    && model.metadata.presentation.quality == crate::model_catalog::QualityTier::Low
            })
            .ok_or_else(|| PiperError::Synthesis("Unknown Piper catalog model".into()))?;
        if crate::model_catalog::model_revision(descriptor).as_deref() != Some(revision) {
            return Err(PiperError::Synthesis(
                "Piper catalog revision does not match".into(),
            ));
        }
        Self::prepare_with_revision(
            root,
            model_id,
            Path::new("model.onnx"),
            Path::new("model.onnx.json"),
            runtime,
            Some(revision),
        )
    }

    fn prepare_with_revision(
        root: &Path,
        model_id: &str,
        model_path: &Path,
        config_path: &Path,
        runtime: Arc<dyn PiperRuntime>,
        explicit_low_revision: Option<&str>,
    ) -> Result<Self, PiperError> {
        if explicit_low_revision.is_none() {
            super::validate_model_quality(model_id).map_err(PiperError::Synthesis)?;
        }
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
        let model_usage = crate::model_store::model_usage::ModelUsageLease::acquire(&namespace)
            .map_err(|error| PiperError::Io(error.to_string()))?;
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
        if explicit_low_revision.is_none() {
            validate_model_files(&model, &config, false)?;
        }
        if !runtime.supports_explicit_model_paths() {
            return Err(PiperError::RuntimeUnavailable(
                "runtime does not support per-request model paths".into(),
            ));
        }
        let prepared = Self {
            explicit_low_revision: explicit_low_revision.map(str::to_owned),
            _model_usage: model_usage,
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
        let allows_low = self.explicit_low_revision.is_some();
        validate_model_files(&self.model, &self.config, allows_low)?;
        if let Some(revision) = &self.explicit_low_revision {
            let model_hash = crate::cache::sha256_file(&self.model)
                .map_err(|error| PiperError::Io(error.to_string()))?;
            let config_hash = crate::cache::sha256_file(&self.config)
                .map_err(|error| PiperError::Io(error.to_string()))?;
            if crate::model_catalog::revision_from_hashes([
                model_hash.as_str(),
                config_hash.as_str(),
            ])
            .as_ref()
                != Some(revision)
            {
                return Err(PiperError::Synthesis(
                    "Installed model does not match its catalog artifacts".into(),
                ));
            }
        }
        super::piper_runtime_registry::initialize_runtime(
            &self.runtime,
            &self.model,
            &self.config,
            allows_low,
        )?;
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
        let _transaction = super::piper_runtime_registry::cancellable_transaction(cancel)?;
        if cancel.is_cancelled() {
            return Err(PiperError::Cancelled);
        }
        if text.trim().is_empty() {
            return Err(PiperError::EmptyOutput);
        }
        self.initialize()?;
        if cancel.is_cancelled() {
            return Err(PiperError::Cancelled);
        }
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
        self.runtime
            .synthesize(text, &wav, &|| cancel.is_cancelled())?;
        if cancel.is_cancelled() {
            return Err(PiperError::Cancelled);
        }
        publish_piper_audio_cancellable(&wav, output, &|| cancel.is_cancelled()).map(|_| ())
    }
}

fn validate_model_files(
    model: &Path,
    config: &Path,
    allows_low_quality: bool,
) -> Result<(), PiperError> {
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
    super::validate_selected_model_files(model, config, allows_low_quality)
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
    select_model(config, None)?;
    if text.trim().is_empty() {
        return Err(PiperError::EmptyOutput);
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|e| PiperError::Io(e.to_string()))?;
    }
    let runtime = registered_runtime()
        .ok_or_else(|| PiperError::RuntimeUnavailable("no embedded runtime registered".into()))?;
    synthesize_with_runtime(config, text, output, cancel, runtime)
}

/// A prepared session pins the adapter rather than consulting mutable registration.
pub fn synthesize_with_runtime(
    config: &PiperConfig,
    text: &str,
    output: &Path,
    cancel: &CancellationToken,
    runtime: Arc<dyn PiperRuntime>,
) -> Result<PathBuf, PiperError> {
    synthesize_selected_model(config, text, output, cancel, runtime, false)
}

pub(crate) fn synthesize_selected_model(
    config: &PiperConfig,
    text: &str,
    output: &Path,
    cancel: &CancellationToken,
    runtime: Arc<dyn PiperRuntime>,
    allows_low_quality: bool,
) -> Result<PathBuf, PiperError> {
    if cancel.is_cancelled() {
        return Err(PiperError::Cancelled);
    }
    if !allows_low_quality {
        select_model(config, None)?;
    }
    let model = config.model_for_language(None);
    if text.trim().is_empty() {
        return Err(PiperError::EmptyOutput);
    }
    let _transaction = super::piper_runtime_registry::cancellable_transaction(cancel)?;
    validate_model_files(model, &config.config, allows_low_quality)?;
    super::piper_runtime_registry::initialize_runtime(
        &runtime,
        model,
        &config.config,
        allows_low_quality,
    )?;
    if cancel.is_cancelled() {
        return Err(PiperError::Cancelled);
    }
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let staging = tempfile::Builder::new()
        .prefix(".piper-audio-")
        .tempdir_in(parent)
        .map_err(|error| PiperError::Io(error.to_string()))?;
    let wav = staging.path().join("speech.wav");
    runtime.synthesize(text, &wav, &|| cancel.is_cancelled())?;
    validate_wav(&wav)?;
    if cancel.is_cancelled() {
        return Err(PiperError::Cancelled);
    }
    publish_piper_audio_cancellable(&wav, output, &|| cancel.is_cancelled())
}
