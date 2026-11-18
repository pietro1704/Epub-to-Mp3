//! Native providers registered at the shared synthesis boundary.
use super::{
    default_edge_voice, run_edge_synthesis_checked, ConversionRequest, ConversionWorker,
    WorkerError,
};
use crate::{tts::EdgeError, tts_preferences::TtsSelection, tts_session::*};
use std::{fs, sync::Arc};

mod edge;
mod piper;
mod system;
#[cfg(test)]
mod tests;

/// The wire identity remains extensible; only built-in registration is closed.
enum NativeEngine {
    Piper,
    System,
    Edge,
}
impl TryFrom<&str> for NativeEngine {
    type Error = TtsFailure;
    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "piper" => Ok(Self::Piper),
            "system" => Ok(Self::System),
            "edge" => Ok(Self::Edge),
            _ => Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Unknown native provider",
            )),
        }
    }
}

pub(super) fn native_registry(
    worker: &ConversionWorker,
    request: &ConversionRequest,
) -> Result<TtsRegistry, TtsFailure> {
    let context = Arc::new(ProviderContext {
        default_model_root: worker.config.paths.piper_models_dir.clone(),
        staging: worker.config.paths.output_dir.join(&request.job_id),
        request: request.clone(),
        cancel: worker.cancel.clone(),
        platform_tts: worker.platform_tts.clone(),
        platform_gate: worker.platform_gate.clone(),
        adaptive: worker.adaptive.clone(),
        telemetry: worker.telemetry.clone(),
        #[cfg(test)]
        test_edge: worker.test_edge.clone(),
    });
    let mut registry = worker.tts_registry.clone();
    for descriptor in builtin_descriptors()
        .into_iter()
        .filter(|descriptor| !descriptor.targets.iter().any(|target| target == "web"))
    {
        // Explicit host adapters retain precedence over the built-in adapter.
        if registry.descriptors().iter().any(|registered| {
            registered.provider == descriptor.provider && registered.runtime == descriptor.runtime
        }) {
            continue;
        }
        let engine = NativeEngine::try_from(descriptor.provider.as_str())?;
        let configuration = ProviderConfiguration {
            context: context.clone(),
            descriptor,
        };
        let provider: Arc<dyn TtsProvider> = match engine {
            NativeEngine::Piper => Arc::new(piper::PiperProvider(configuration)),
            NativeEngine::System => Arc::new(system::SystemProvider(configuration)),
            NativeEngine::Edge => Arc::new(edge::EdgeProvider(configuration)),
        };
        registry.register(provider)?;
    }
    Ok(registry)
}

struct ProviderContext {
    default_model_root: std::path::PathBuf,
    staging: std::path::PathBuf,
    request: ConversionRequest,
    cancel: crate::piper::CancellationToken,
    platform_tts: Option<Arc<dyn crate::platform_tts::PlatformTts>>,
    platform_gate: Arc<std::sync::Mutex<()>>,
    adaptive: Arc<crate::adaptive::AdaptiveThroughputController>,
    telemetry: Option<crate::tts::Telemetry>,
    #[cfg(test)]
    test_edge: Option<Arc<dyn Fn(&str) -> Result<Vec<u8>, WorkerError> + Send + Sync>>,
}
struct ProviderConfiguration {
    context: Arc<ProviderContext>,
    descriptor: ProviderDescriptor,
}
impl ProviderConfiguration {
    fn selection(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<TtsSelection, TtsFailure> {
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
        let mut captured = TtsSelection {
            session: None,
            engine: selection.provider.clone(),
            model_id: selection.model_id.clone(),
            voice: selection.voice.clone(),
        };
        if selection.model_revision.is_some() {
            selection.validate(&self.descriptor, language)?;
            captured.session = Some(selection.clone());
        }
        // Revision-less local paths retain their existing model-ID contract.
        // Catalog captures still require exact catalog and runtime revisions.
        captured
            .validate(Some(language))
            .map_err(|message| TtsFailure::new(FailureKind::InvalidSelection, message))?;
        Ok(captured)
    }
    fn session(
        &self,
        selection: SessionSelection,
        artifacts: std::collections::BTreeMap<String, String>,
        reusable: bool,
    ) -> Result<SessionContext, TtsFailure> {
        fs::create_dir_all(&self.context.staging)
            .map_err(|error| TtsFailure::new(FailureKind::Unavailable, error.to_string()))?;
        Ok(SessionContext {
            provider: self.context.clone(),
            identity: ResolvedIdentity {
                selection,
                runtime_revision: self.descriptor.revision.clone(),
                artifacts,
                reusable,
            },
        })
    }
}
struct SessionContext {
    provider: Arc<ProviderContext>,
    identity: ResolvedIdentity,
}
impl SessionContext {
    fn check(&self, context: &SynthesisContext<'_>) -> Result<(), WorkerError> {
        if self.provider.cancel.is_cancelled() {
            return Err(WorkerError::Cancelled);
        }
        if (context.replaced)() {
            return Err(WorkerError::PlaybackWindowChanged);
        }
        Ok(())
    }
}
fn publish_audio(
    context: &SynthesisContext<'_>,
    sink: &mut AudioSink,
    synthesize: impl FnOnce() -> Result<Vec<u8>, WorkerError>,
) -> Result<(), TtsFailure> {
    context.check()?;
    let result = synthesize().map_err(failure_from_worker);
    context.check()?;
    sink.write(&result?)
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
    if let WorkerError::Synthesis(failure) = error {
        return failure;
    }
    let (kind, retry_after_ms) = match &error {
        WorkerError::InvalidSelection(_) => (FailureKind::InvalidSelection, None),
        WorkerError::Piper(
            crate::piper::PiperError::RuntimeUnavailable(_)
            | crate::piper::PiperError::IncompatibleAbi(_)
            | crate::piper::PiperError::MissingModel(_)
            | crate::piper::PiperError::MissingConfig(_),
        ) => (FailureKind::Unavailable, None),
        WorkerError::Piper(
            crate::piper::PiperError::InvalidWav(_) | crate::piper::PiperError::EmptyOutput,
        ) => (FailureKind::InvalidAudio, None),
        WorkerError::Io(error) if error.kind() == std::io::ErrorKind::NotFound => {
            (FailureKind::Unavailable, None)
        }
        WorkerError::Cancelled
        | WorkerError::Edge(EdgeError::Cancelled)
        | WorkerError::Piper(crate::piper::PiperError::Cancelled) => (FailureKind::Cancelled, None),
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
        _ => WorkerError::Synthesis(failure),
    }
}
