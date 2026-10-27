//! Existing native runtimes adapted to the common synthesis seam.
use super::{
    default_edge_voice, run_edge_synthesis_checked, ConversionRequest, ConversionWorker,
    WorkerError,
};
use crate::{tts::EdgeError, tts_preferences::TtsSelection, tts_session::*};
use std::{fs, sync::Arc};

pub(super) struct NativeProvider<'a> {
    pub worker: &'a ConversionWorker,
    pub request: &'a ConversionRequest,
    pub descriptor: ProviderDescriptor,
}
struct NativeSession {
    _model_usage: Option<crate::model_store::model_usage::ModelUsageLease>,
    piper_runtime: Option<Arc<dyn crate::piper::PiperRuntime>>,
    artifact_versions: Option<(String, String)>,
    cancel: crate::piper::CancellationToken,
    platform_tts: Option<Arc<dyn crate::platform_tts::PlatformTts>>,
    platform_gate: Arc<std::sync::Mutex<()>>,
    adaptive: Arc<crate::adaptive::AdaptiveThroughputController>,
    telemetry: Option<crate::tts::Telemetry>,
    model_paths: (std::path::PathBuf, std::path::PathBuf),
    model_root: std::path::PathBuf,
    selection: TtsSelection,
    identity: ResolvedIdentity,
    staging: std::path::PathBuf,
    #[cfg(test)]
    test_edge: Option<Arc<dyn Fn(&str) -> Result<Vec<u8>, WorkerError> + Send + Sync>>,
}
impl TtsProvider for NativeProvider<'_> {
    fn descriptor(&self) -> ProviderDescriptor {
        self.descriptor.clone()
    }
    fn prepare(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<Box<dyn TtsSession>, TtsFailure> {
        if selection.version != CONTRACT_VERSION
            || selection.provider != self.descriptor.provider
            || selection.runtime != self.descriptor.runtime
            || !selection.options.is_empty()
        {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Unsupported native selection",
            ));
        }
        let mut legacy = TtsSelection {
            session: None,
            engine: selection.provider.clone(),
            model_id: selection.model_id.clone(),
            voice: selection.voice.clone(),
        };
        if selection.model_revision.is_some() || selection.provider == "kokoro" {
            selection.validate(&self.descriptor, language)?;
            if let Some(model_id) = &selection.model_id {
                if selection.provider != "kokoro" {
                    let manifest = crate::model_store::ModelStore::catalog_manifest(model_id)
                        .map_err(|error| {
                            TtsFailure::new(FailureKind::Unavailable, error.to_string())
                        })?;
                    let store = crate::model_store::ModelStore::new(
                        self.request
                            .models_root
                            .as_ref()
                            .unwrap_or(&self.worker.config.paths.piper_models_dir),
                    );
                    if !store.is_manifest_installed(&manifest).map_err(|error| {
                        TtsFailure::new(FailureKind::Unavailable, error.to_string())
                    })? {
                        return Err(TtsFailure::new(
                            FailureKind::Unavailable,
                            "Installed model does not match its catalog artifacts",
                        ));
                    }
                }
            }
            legacy.session = Some(selection.clone());
        }
        legacy
            .validate(Some(language))
            .map_err(|message| TtsFailure::new(FailureKind::InvalidSelection, message))?;
        if legacy.engine == "edge" && legacy.voice.is_none() {
            legacy.voice = Some(default_edge_voice(Some(language)).into());
        }
        let mut resolved = selection.clone();
        resolved.voice = legacy.voice.clone();
        let mut artifacts = std::collections::BTreeMap::new();
        let paths = self.worker.selection_model_paths(self.request, &legacy);
        let model_usage = match legacy.engine.as_str() {
            "piper" | "kokoro" => {
                let namespace = if legacy.engine == "piper" {
                    paths
                        .0
                        .parent()
                        .ok_or_else(|| {
                            TtsFailure::new(FailureKind::Unavailable, "Model namespace is missing")
                        })?
                        .to_owned()
                } else {
                    self.request
                        .models_root
                        .as_ref()
                        .unwrap_or(&self.worker.config.paths.piper_models_dir)
                        .join(legacy.model_id.as_deref().unwrap_or("kokoro-82m"))
                };
                Some(
                    crate::model_store::model_usage::ModelUsageLease::acquire(&namespace).map_err(
                        |error| TtsFailure::new(FailureKind::Unavailable, error.to_string()),
                    )?,
                )
            }
            _ => None,
        };
        if legacy.engine == "piper" {
            crate::piper::validate_model_file_quality(&paths.0, &paths.1).map_err(|error| {
                TtsFailure::new(FailureKind::InvalidSelection, error.to_string())
            })?;
        }
        let artifact_versions = if legacy.engine == "piper" {
            Some((
                file_version(&paths.0).map_err(failure_from_worker)?,
                file_version(&paths.1).map_err(failure_from_worker)?,
            ))
        } else {
            None
        };
        if legacy.engine == "piper" {
            let (model, config) = self.worker.selection_model_paths(self.request, &legacy);
            for (name, path) in [("model", model), ("config", config)] {
                artifacts.insert(
                    name.into(),
                    crate::cache::sha256_file(path).map_err(|error| {
                        TtsFailure::new(FailureKind::Unavailable, error.to_string())
                    })?,
                );
            }
        }
        if legacy.engine == "kokoro" {
            let root = self
                .request
                .models_root
                .as_ref()
                .unwrap_or(&self.worker.config.paths.piper_models_dir)
                .join(legacy.model_id.as_deref().unwrap_or("kokoro-82m"));
            super::kokoro_model_identity::validate_provenance(
                &root,
                legacy.model_id.as_deref().unwrap_or("kokoro-82m"),
            )
            .map_err(failure_from_worker)?;
            artifacts = super::kokoro_model_identity::extracted_identity(
                &root,
                cfg!(feature = "kokoro-sherpa-runtime"),
            )
            .map_err(failure_from_worker)?;
        }
        let identity = ResolvedIdentity {
            selection: resolved,
            runtime_revision: self.descriptor.revision.clone(),
            artifacts,
            reusable: !matches!(legacy.engine.as_str(), "system" | "kokoro"),
        };
        let piper_runtime = crate::piper::registered_runtime();
        if legacy.engine == "piper"
            && selection.model_revision.is_some()
            && piper_runtime
                .as_ref()
                .is_none_or(|runtime| !runtime.supports_explicit_model_paths())
        {
            return Err(TtsFailure::new(
                FailureKind::Unavailable,
                "Piper runtime cannot honor the captured model selection",
            ));
        }
        let staging = self
            .worker
            .config
            .paths
            .output_dir
            .join(&self.request.job_id);
        fs::create_dir_all(&staging)
            .map_err(|error| TtsFailure::new(FailureKind::Unavailable, error.to_string()))?;
        Ok(Box::new(NativeSession {
            _model_usage: model_usage,
            piper_runtime,
            artifact_versions,
            cancel: self.worker.cancel.clone(),
            platform_tts: self.worker.platform_tts.clone(),
            platform_gate: self.worker.platform_gate.clone(),
            adaptive: self.worker.adaptive.clone(),
            telemetry: self.worker.telemetry.clone(),
            model_paths: self.worker.selection_model_paths(self.request, &legacy),
            model_root: self
                .request
                .models_root
                .as_ref()
                .unwrap_or(&self.worker.config.paths.piper_models_dir)
                .join(legacy.model_id.as_deref().unwrap_or_default()),
            #[cfg(test)]
            test_edge: self.worker.test_edge.clone(),
            selection: legacy,
            identity,
            staging,
        }))
    }
}
impl TtsSession for NativeSession {
    fn identity(&self) -> &ResolvedIdentity {
        &self.identity
    }
    fn synthesize(
        &mut self,
        text: &str,
        context: &SynthesisContext<'_>,
        sink: &mut AudioSink,
    ) -> Result<(), TtsFailure> {
        context.check()?;
        let result = self
            .synthesize_audio(text, context)
            .map_err(failure_from_worker);
        context.check()?;
        if self.selection.engine == "kokoro"
            && super::kokoro_model_identity::extracted_identity(
                &self.model_root,
                cfg!(feature = "kokoro-sherpa-runtime"),
            )
            .map_err(failure_from_worker)?
                != self.identity.artifacts
        {
            return Err(TtsFailure::new(
                FailureKind::Unavailable,
                "Kokoro artifacts changed during synthesis",
            ));
        }
        sink.write(&result?)
    }
}
impl NativeSession {
    fn synthesize_audio(
        &self,
        segment: &str,
        context: &SynthesisContext<'_>,
    ) -> Result<Vec<u8>, WorkerError> {
        let selection = &self.selection;
        let language = Some(context.language);
        let staging = tempfile::tempdir_in(&self.staging)?;
        let path = staging.path().join("segment.mp3");
        if self.cancel.is_cancelled() {
            return Err(WorkerError::Cancelled);
        }
        if (context.replaced)() {
            return Err(WorkerError::PlaybackWindowChanged);
        }
        if selection.engine == "kokoro" {
            let root = &self.model_root;
            if super::kokoro_model_identity::extracted_identity(
                root,
                cfg!(feature = "kokoro-sherpa-runtime"),
            )? != self.identity.artifacts
            {
                return Err(WorkerError::Unsupported(
                    "Kokoro artifacts changed after session preparation".into(),
                ));
            }
            #[cfg(feature = "kokoro-sherpa-runtime")]
            return crate::kokoro_sherpa::synthesize_wav(&root, segment)
                .map_err(|error| WorkerError::PlatformTts(error.to_string()));
            #[cfg(not(feature = "kokoro-sherpa-runtime"))]
            return crate::tts_runtime::synthesize_kokoro(&root, segment)
                .map_err(|error| WorkerError::PlatformTts(error.to_string()));
        }

        if selection.engine == "system" {
            let adapter = self.platform_tts.as_ref().ok_or_else(|| {
                WorkerError::PlatformTts("No installed system speech adapter".into())
            })?;
            let _guard = loop {
                if self.cancel.is_cancelled() {
                    return Err(WorkerError::Cancelled);
                }
                if (context.replaced)() {
                    return Err(WorkerError::PlaybackWindowChanged);
                }
                match self.platform_gate.try_lock() {
                    Ok(guard) => break guard,
                    Err(std::sync::TryLockError::Poisoned(_)) => {
                        return Err(WorkerError::PlatformTts(
                            "system speech lock poisoned".into(),
                        ))
                    }
                    Err(std::sync::TryLockError::WouldBlock) => {
                        std::thread::sleep(std::time::Duration::from_millis(25))
                    }
                }
            };
            let started = std::time::Instant::now();
            let deadline = std::time::Duration::from_secs(30);
            let wav = path.with_extension("wav");
            let cancelled = || {
                self.cancel.is_cancelled() || (context.replaced)() || started.elapsed() >= deadline
            };
            adapter
                .synthesize_wav(segment, language.unwrap_or("pt-BR"), &wav, &cancelled)
                .map_err(WorkerError::PlatformTts)?;
            if started.elapsed() >= deadline {
                return Err(WorkerError::PlatformTts(
                    "System speech deadline exceeded".into(),
                ));
            }
            return read_native_audio(&wav);
        }
        if selection.engine == "edge" {
            #[cfg(test)]
            if let Some(edge) = &self.test_edge {
                return edge(segment);
            }
            let result = run_edge_synthesis_checked(
                crate::tts::synthesize_with_reference_client(
                    segment,
                    selection
                        .voice
                        .as_deref()
                        .unwrap_or_else(|| default_edge_voice(language)),
                    Arc::clone(&self.adaptive),
                    self.telemetry.clone(),
                ),
                &|| self.cancel.is_cancelled() || (context.replaced)(),
                crate::tts::reference_synthesis_timeout_for_text(segment.len()),
            );
            if (context.replaced)() {
                return Err(WorkerError::PlaybackWindowChanged);
            }
            return result;
        }
        let (model, config) = &self.model_paths;
        if cfg!(target_os = "android") {
            super::ensure_android_piper_runtime(crate::piper::piper_runtime_status())?;
        }
        let wav = path.with_extension("wav");
        let mut config = crate::piper::PiperConfig::new(model, config);
        config.chunk_chars = std::env::var("PIPER_CHUNK_CHARS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(5_000);
        if self.artifact_versions.as_ref()
            != Some(&(file_version(model)?, file_version(&config.config)?))
        {
            return Err(WorkerError::Piper(
                "Model artifacts changed after session preparation".into(),
            ));
        }
        let runtime = self
            .piper_runtime
            .clone()
            .ok_or_else(|| WorkerError::Piper("No embedded Piper runtime is registered".into()))?;
        crate::piper::synthesize_with_runtime(&config, segment, &wav, &self.cancel, runtime)
            .map_err(|error| WorkerError::Piper(error.to_string()))?;
        if self.artifact_versions.as_ref()
            != Some(&(file_version(model)?, file_version(&config.config)?))
        {
            return Err(WorkerError::Piper(
                "Model artifacts changed during synthesis".into(),
            ));
        }
        read_native_audio(&wav)
    }
}
fn file_version(path: &std::path::Path) -> Result<String, WorkerError> {
    let metadata = fs::metadata(path)?;
    let modified = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    #[cfg(unix)]
    let identity = {
        use std::os::unix::fs::MetadataExt;
        format!("{}:{}", metadata.dev(), metadata.ino())
    };
    #[cfg(not(unix))]
    let identity = format!("{:?}", metadata.created().ok());
    Ok(format!("{identity}:{}:{modified}", metadata.len()))
}
fn read_native_audio(path: &std::path::Path) -> Result<Vec<u8>, WorkerError> {
    use std::io::Read;
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(MAX_SEGMENT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_SEGMENT_BYTES {
        return Err(WorkerError::PlatformTts(
            "Native segment exceeds its byte capacity".into(),
        ));
    }
    Ok(bytes)
}
pub(super) fn failure_from_worker(error: WorkerError) -> TtsFailure {
    let (kind, retry_after_ms) = match &error {
        WorkerError::Io(error) if error.kind() == std::io::ErrorKind::NotFound => {
            (FailureKind::Unavailable, None)
        }
        WorkerError::Cancelled | WorkerError::Edge(EdgeError::Cancelled) => {
            (FailureKind::Cancelled, None)
        }
        WorkerError::PlaybackWindowChanged => (FailureKind::Replaced, None),
        WorkerError::Edge(EdgeError::RateLimited { retry_after, .. }) => (
            FailureKind::RateLimited,
            Some(
                retry_after
                    .unwrap_or(std::time::Duration::from_secs(30))
                    .as_millis() as u64,
            ),
        ),
        _ => (FailureKind::Synthesis, None),
    };
    TtsFailure {
        kind,
        message: error.to_string(),
        retry_after_ms,
    }
}
pub(super) fn worker_from_failure(failure: TtsFailure) -> WorkerError {
    match failure.kind {
        FailureKind::Cancelled => WorkerError::Cancelled,
        FailureKind::Replaced => WorkerError::PlaybackWindowChanged,
        _ => WorkerError::PlatformTts(failure.message),
    }
}
