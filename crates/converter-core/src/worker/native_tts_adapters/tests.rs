use super::*;

#[test]
fn provider_failures_keep_classification_and_retry_after_across_worker_boundary() {
    for kind in [
        FailureKind::Unavailable,
        FailureKind::InvalidSelection,
        FailureKind::InvalidAudio,
        FailureKind::Synthesis,
        FailureKind::RateLimited,
    ] {
        let failure = TtsFailure {
            kind,
            message: "original provider failure".into(),
            retry_after_ms: (kind == FailureKind::RateLimited).then_some(1234),
        };
        assert_eq!(
            failure_from_worker(worker_from_failure(failure.clone())),
            failure
        );
    }
    assert!(matches!(
        worker_from_failure(TtsFailure::new(FailureKind::Cancelled, "cancel")),
        WorkerError::Cancelled
    ));
    assert!(matches!(
        worker_from_failure(TtsFailure::new(FailureKind::Replaced, "move")),
        WorkerError::PlaybackWindowChanged
    ));
}

#[test]
fn piper_failures_keep_unavailable_invalid_audio_and_cancellation_distinct() {
    use crate::piper::PiperError;
    for (error, kind) in [
        (
            PiperError::RuntimeUnavailable("missing".into()),
            FailureKind::Unavailable,
        ),
        (
            PiperError::MissingModel("missing.onnx".into()),
            FailureKind::Unavailable,
        ),
        (PiperError::EmptyOutput, FailureKind::InvalidAudio),
        (
            PiperError::InvalidWav("truncated".into()),
            FailureKind::InvalidAudio,
        ),
        (PiperError::Timeout, FailureKind::Synthesis),
        (PiperError::Cancelled, FailureKind::Cancelled),
    ] {
        assert_eq!(failure_from_worker(WorkerError::Piper(error)).kind, kind);
    }
}

fn fixture(root: &std::path::Path) -> (ConversionWorker, ConversionRequest) {
    let paths = crate::paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_path_buf(),
    );
    let worker = ConversionWorker::new(crate::config::AppConfig::from_paths(paths)).unwrap();
    let request = ConversionRequest {
        input: root.join("unused.epub"),
        job_id: "provider-contract".into(),
        tts_preferences: None,
        models_root: None,
        engine: None,
        voice: None,
        language: None,
        piper_model: None,
        piper_config: None,
        chapter_indices: None,
        no_parallel: true,
    };
    (worker, request)
}

#[test]
fn registry_preserves_explicit_local_model_identity_without_catalog_claims() {
    let root = tempfile::tempdir().unwrap();
    let (worker, mut request) = fixture(root.path());
    let model = root.path().join("en_US-personal-medium.onnx");
    let config = root.path().join("voice.json");
    fs::write(&model, b"private model fixture").unwrap();
    fs::write(&config, b"{}").unwrap();
    request.piper_model = Some(model.clone());
    request.piper_config = Some(config.clone());
    let selected = TtsSelection {
        engine: "piper".into(),
        model_id: Some("en_US-personal-medium".into()),
        voice: None,
        session: None,
    };
    let selection = SessionSelection::from_legacy(&selected).unwrap();
    let registry = native_registry(&worker, &request).unwrap();
    let session = registry.prepare(&selection, "en-US").unwrap();
    assert_eq!(session.identity().selection, selection);
    assert_eq!(
        session.identity().artifacts["model"],
        crate::cache::sha256_file(&model).unwrap()
    );
    assert_eq!(
        session.identity().artifacts["config"],
        crate::cache::sha256_file(&config).unwrap()
    );
    let mut invalid = selection.clone();
    invalid.model_revision = Some("uncatalogued-revision".into());
    assert!(registry.prepare(&invalid, "en-US").is_err());
    invalid = selection.clone();
    invalid.runtime = "edge-websocket".into();
    assert!(registry.prepare(&invalid, "en-US").is_err());
    drop(registry);
    drop(worker);
    assert_eq!(session.identity().selection, selection);
    assert_eq!(fs::read(model).unwrap(), b"private model fixture");
}

#[test]
fn explicit_adapter_overrides_builtin_with_the_same_provider_and_runtime() {
    struct Override(ProviderDescriptor);
    struct Prepared(ResolvedIdentity);
    impl TtsProvider for Override {
        fn descriptor(&self) -> ProviderDescriptor {
            self.0.clone()
        }
        fn prepare(
            &self,
            selection: &SessionSelection,
            _: &str,
        ) -> Result<Box<dyn TtsSession>, TtsFailure> {
            Ok(Box::new(Prepared(ResolvedIdentity {
                selection: selection.clone(),
                runtime_revision: self.0.revision.clone(),
                artifacts: Default::default(),
                reusable: false,
            })))
        }
    }
    impl TtsSession for Prepared {
        fn identity(&self) -> &ResolvedIdentity {
            &self.0
        }
        fn synthesize(
            &mut self,
            _: &str,
            context: &SynthesisContext<'_>,
            sink: &mut AudioSink,
        ) -> Result<(), TtsFailure> {
            context.check()?;
            sink.write(include_bytes!(
                "../../../../../tests/fixtures/audio/mono-24000-48k.mp3"
            ))
        }
    }
    let root = tempfile::tempdir().unwrap();
    let (worker, request) = fixture(root.path());
    let mut descriptor = builtin_descriptors()
        .into_iter()
        .find(|d| d.provider == "system")
        .unwrap();
    descriptor.revision = "host-adapter".into();
    descriptor.capabilities.audio_formats = vec![AudioFormat::Mp3];
    let mut custom = TtsRegistry::default();
    custom.register(Arc::new(Override(descriptor))).unwrap();
    let worker = worker.with_tts_registry(custom);
    let registry = native_registry(&worker, &request).unwrap();
    assert_eq!(registry.descriptors().len(), 3);
    let selection = SessionSelection::from_legacy(&TtsSelection {
        engine: "system".into(),
        model_id: None,
        voice: None,
        session: None,
    })
    .unwrap();
    let mut session = registry.prepare(&selection, "pt-BR").unwrap();
    assert_eq!(session.identity().runtime_revision, "host-adapter");
    let mut sink = AudioSink::new(AudioFormat::Mp3, MAX_SEGMENT_BYTES);
    session
        .synthesize(
            "Override",
            &SynthesisContext {
                language: "pt-BR",
                cancelled: &|| false,
                replaced: &|| false,
            },
            &mut sink,
        )
        .unwrap();
    crate::pcm::validate_mp3(&sink.into_mp3().unwrap()).unwrap();
}
