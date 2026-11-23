use super::*;

pub(super) struct PiperProvider(pub(super) ProviderConfiguration);
impl TtsProvider for PiperProvider {
    fn descriptor(&self) -> ProviderDescriptor {
        self.0.descriptor.clone()
    }
    fn validate_selection(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<(), TtsFailure> {
        self.0.selection(selection, language).map(|_| ())
    }
    fn prepare(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<Box<dyn TtsSession>, TtsFailure> {
        let captured = self.0.selection(selection, language)?;
        let context = &self.0.context;
        let allows_low_quality = selection.explicit_low_piper_model().is_some();
        if selection.model_revision.is_some() && !allows_low_quality {
            if let Some(model_id) = &selection.model_id {
                let manifest = crate::model_store::ModelStore::catalog_manifest(model_id).map_err(
                    |error| TtsFailure::new(FailureKind::Unavailable, error.to_string()),
                )?;
                let store = crate::model_store::ModelStore::new(
                    context
                        .request
                        .models_root
                        .as_ref()
                        .unwrap_or(&context.default_model_root),
                );
                if !store
                    .is_manifest_installed(&manifest)
                    .map_err(|error| TtsFailure::new(FailureKind::Unavailable, error.to_string()))?
                {
                    return Err(TtsFailure::new(
                        FailureKind::Unavailable,
                        "Installed model does not match its catalog artifacts",
                    ));
                }
            }
        }
        let paths = super::super::selection_model_paths::selection_model_paths(
            &context.default_model_root,
            &context.request,
            &captured,
        );
        let namespace = paths.0.parent().ok_or_else(|| {
            TtsFailure::new(FailureKind::Unavailable, "Model namespace is missing")
        })?;
        let model_usage = crate::model_store::model_usage::ModelUsageLease::acquire(namespace)
            .map_err(|error| TtsFailure::new(FailureKind::Unavailable, error.to_string()))?;
        crate::piper::validate_selected_model_files(&paths.0, &paths.1, allows_low_quality)
            .map_err(|error| TtsFailure::new(FailureKind::InvalidSelection, error.to_string()))?;
        let artifact_versions = (
            file_version(&paths.0).map_err(failure_from_worker)?,
            file_version(&paths.1).map_err(failure_from_worker)?,
        );
        let mut artifacts = std::collections::BTreeMap::new();
        for (name, path) in [("model", &paths.0), ("config", &paths.1)] {
            artifacts.insert(
                name.into(),
                crate::cache::sha256_file(path).map_err(|error| {
                    TtsFailure::new(FailureKind::Unavailable, error.to_string())
                })?,
            );
        }
        if allows_low_quality
            && crate::model_catalog::revision_from_hashes([
                artifacts["model"].as_str(),
                artifacts["config"].as_str(),
            ]) != selection.model_revision
        {
            return Err(TtsFailure::new(
                FailureKind::Unavailable,
                "Installed model does not match its catalog artifacts",
            ));
        }
        let runtime = crate::piper::registered_runtime();
        if selection.model_revision.is_some()
            && runtime
                .as_ref()
                .is_none_or(|runtime| !runtime.supports_explicit_model_paths())
        {
            return Err(TtsFailure::new(
                FailureKind::Unavailable,
                "Piper runtime cannot honor the captured model selection",
            ));
        }
        Ok(Box::new(PiperSession {
            context: self.0.session(selection.clone(), artifacts, true)?,
            _model_usage: model_usage,
            runtime,
            artifact_versions,
            allows_low_quality,
            paths,
        }))
    }
}
struct PiperSession {
    context: SessionContext,
    _model_usage: crate::model_store::model_usage::ModelUsageLease,
    runtime: Option<Arc<dyn crate::piper::PiperRuntime>>,
    artifact_versions: (String, String),
    allows_low_quality: bool,
    paths: (std::path::PathBuf, std::path::PathBuf),
}
impl TtsSession for PiperSession {
    fn identity(&self) -> &ResolvedIdentity {
        &self.context.identity
    }
    fn synthesize(
        &mut self,
        text: &str,
        context: &SynthesisContext<'_>,
        sink: &mut AudioSink,
    ) -> Result<(), TtsFailure> {
        publish_audio(context, sink, || self.synthesize_audio(text, context))
    }
}
impl PiperSession {
    fn synthesize_audio(
        &self,
        segment: &str,
        context: &SynthesisContext<'_>,
    ) -> Result<Vec<u8>, WorkerError> {
        self.context.check(context)?;
        let shared = &self.context.provider;
        let staging = tempfile::tempdir_in(&shared.staging)?;
        let wav = staging.path().join("segment.wav");
        let (model, config) = &self.paths;
        if cfg!(target_os = "android") {
            super::super::ensure_android_piper_runtime(crate::piper::piper_runtime_status())?;
        }
        let mut config = crate::piper::PiperConfig::new(model, config);
        config.chunk_chars = std::env::var("PIPER_CHUNK_CHARS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(5_000);
        if self.artifact_versions != (file_version(model)?, file_version(&config.config)?) {
            return Err(WorkerError::InvalidSelection(
                "Model artifacts changed after session preparation".into(),
            ));
        }
        let runtime = self.runtime.clone().ok_or_else(|| {
            WorkerError::Piper(crate::piper::PiperError::RuntimeUnavailable(
                "No embedded Piper runtime is registered".into(),
            ))
        })?;
        let timeout_seconds = std::env::var("RUST_CHAPTER_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(if cfg!(target_os = "android") {
                300
            } else {
                180
            });
        let cancel = shared
            .cancel
            .with_timeout(std::time::Duration::from_secs(timeout_seconds));
        // Local synthesis is pure CPU: while the app is backgrounded the segment is followed by a rest that
        // keeps the process under the OS background CPU limit (otherwise iOS kills it within a minute).
        let duty_cycle = super::super::background_pacing::DutyCycle::begin();
        let result = crate::piper::synthesize_selected_model(
            &config,
            segment,
            &wav,
            &cancel,
            runtime,
            self.allows_low_quality,
        );
        duty_cycle.rest_if_backgrounded(&|| shared.cancel.is_cancelled());
        if shared.cancel.is_cancelled() {
            return Err(WorkerError::Cancelled);
        }
        if cancel.timed_out() {
            return Err(WorkerError::Piper(crate::piper::PiperError::Timeout));
        }
        result.map_err(WorkerError::Piper)?;
        if self.artifact_versions != (file_version(model)?, file_version(&config.config)?) {
            return Err(WorkerError::InvalidSelection(
                "Model artifacts changed during synthesis".into(),
            ));
        }
        read_native_audio(&wav)
    }
}
