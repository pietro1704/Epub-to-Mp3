#[test]
fn registered_runtime_runs_through_real_worker_without_provider_branches() {
    use crate::tts_preferences::{TtsPreferences, TtsSelection};
    use crate::tts_session::*;
    struct ContractProvider(Arc<AtomicUsize>);
    struct ContractSession(ResolvedIdentity);
    impl TtsProvider for ContractProvider {
        fn descriptor(&self) -> ProviderDescriptor {
            ProviderDescriptor {
                provider: "contract".into(),
                runtime: "pcm-fixture".into(),
                revision: "1".into(),
                targets: vec!["test".into()],
                capabilities: TtsCapabilities {
                    audio_formats: vec![AudioFormat::Pcm16 {
                        sample_rate: 24_000,
                        channels: 1,
                    }],
                    languages: vec!["pt".into()],
                    voices: vec!["a".into(), "b".into()],
                    voice_selection: true,
                    configurable_options: Vec::new(),
                    max_text_chars: 96,
                    cancellation: CancellationCapability::AfterCall,
                    streaming: false,
                    audio_bytes: true,
                    online: false,
                },
            }
        }
        fn prepare(
            &self,
            selection: &SessionSelection,
            _: &str,
        ) -> Result<Box<dyn TtsSession>, TtsFailure> {
            self.0.fetch_add(1, Ordering::AcqRel);
            Ok(Box::new(ContractSession(ResolvedIdentity {
                selection: selection.clone(),
                runtime_revision: "1".into(),
                artifacts: Default::default(),
                reusable: true,
            })))
        }
    }
    impl TtsSession for ContractSession {
        fn identity(&self) -> &ResolvedIdentity {
            &self.0
        }
        fn synthesize(
            &mut self,
            text: &str,
            context: &SynthesisContext<'_>,
            sink: &mut AudioSink,
        ) -> Result<(), TtsFailure> {
            context.check()?;
            if text.chars().count() > 96 {
                return Err(TtsFailure::new(
                    FailureKind::Synthesis,
                    "Runtime text capacity exceeded",
                ));
            }
            let frequency = if self.0.selection.voice.as_deref() == Some("a") {
                220.0
            } else {
                440.0
            };
            let pcm: Vec<_> = (0..4800)
                .flat_map(|index| {
                    (((index as f64 * frequency * std::f64::consts::TAU / 24_000.0).sin() * 8000.0)
                        as i16)
                        .to_le_bytes()
                })
                .collect();
            sink.write(&pcm)
        }
    }
    let temp = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temp.path().to_path_buf(),
    ));
    let mut registry = TtsRegistry::default();
    let prepared = Arc::new(AtomicUsize::new(0));
    registry
        .register(Arc::new(ContractProvider(prepared.clone())))
        .unwrap();
    let worker = ConversionWorker::new(config)
        .unwrap()
        .with_tts_registry(registry);
    let mut outputs = Vec::new();
    for voice in ["a", "b"] {
        let session = SessionSelection {
            version: 2,
            provider: "contract".into(),
            runtime: "pcm-fixture".into(),
            model_id: None,
            model_revision: None,
            voice: Some(voice.into()),
            options: Default::default(),
        };
        let preferences = TtsPreferences {
            primary: TtsSelection {
                engine: session.provider.clone(),
                model_id: None,
                voice: session.voice.clone(),
                session: Some(session),
            },
            ..TtsPreferences::default()
        };
        let output = temp.path().join(format!("{voice}.mp3"));
        for source_index in [16, 17] {
            worker
                .synthesize_preferences(
                    &preference_test_request(),
                    &preferences,
                    &"A known source sentence for bounded inference. ".repeat(6),
                    &output,
                    source_index,
                    Some("pt-BR"),
                    &std::sync::atomic::AtomicBool::new(false),
                    &Mutex::new(Vec::new()),
                    1,
                )
                .unwrap();
        }
        let encoded = fs::read(&output).unwrap();
        crate::pcm::validate_mp3(&encoded).unwrap();
        let identities: Vec<ResolvedIdentity> =
            crate::cache::read_json(output.with_extension("tts-sessions.json")).unwrap();
        assert_eq!(identities.len(), 1);
        assert_eq!(identities[0].selection.voice.as_deref(), Some(voice));
        outputs.push(encoded);
    }
    let session_count = worker.tts_sessions.lock().unwrap().len();
    assert_eq!(session_count, 2);
    assert_eq!(prepared.load(Ordering::Acquire), 2);
    assert_ne!(outputs[0], outputs[1]);
    let input = temp.path().join("registry.epub");
    platform_test_book_with_text(
        &input,
        &"A complete conversion uses the registered runtime. ".repeat(6),
    );
    let mut request = preference_test_request();
    request.input = input;
    request.job_id = "registered-end-to-end".into();
    request.engine = Some("contract".into());
    let session = SessionSelection {
        version: 2,
        provider: "contract".into(),
        runtime: "pcm-fixture".into(),
        model_id: None,
        model_revision: None,
        voice: Some("a".into()),
        options: Default::default(),
    };
    request.tts_preferences = Some(TtsPreferences {
        primary: TtsSelection {
            engine: "contract".into(),
            model_id: None,
            voice: Some("a".into()),
            session: Some(session),
        },
        ..TtsPreferences::default()
    });
    let manifest = worker.run(request).unwrap();
    assert_eq!(manifest.chapters.len(), 1);
    assert_eq!(manifest.synthesis_sessions.len(), 1);
    assert_eq!(
        manifest.synthesis_sessions[0].selection.runtime,
        "pcm-fixture"
    );
    assert_eq!(
        prepared.load(Ordering::Acquire),
        3,
        "cache and synthesis share one prepared session per job"
    );
}

#[test]
fn explicit_piper_paths_override_managed_defaults_without_leaking_to_secondary_models() {
    use crate::tts_preferences::{TtsPreferences, TtsSelection};
    let temp = tempfile::tempdir().unwrap();
    let worker = ConversionWorker::new(AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temp.path().into(),
    )))
    .unwrap();
    let mut request = preference_test_request();
    let primary = TtsSelection {
        engine: "piper".into(),
        model_id: Some("primary".into()),
        ..Default::default()
    };
    let secondary = TtsSelection {
        engine: "piper".into(),
        model_id: Some("secondary".into()),
        ..Default::default()
    };
    request.tts_preferences = Some(TtsPreferences {
        primary: primary.clone(),
        secondary: Some(secondary.clone()),
        ..Default::default()
    });
    request.models_root = Some(temp.path().join("models"));
    request.piper_model = Some(temp.path().join("models/primary/custom.onnx"));
    request.piper_config = Some(temp.path().join("models/primary/custom.json"));
    assert_eq!(
        worker.selection_model_paths(&request, &primary),
        (
            request.piper_model.clone().unwrap(),
            request.piper_config.clone().unwrap()
        )
    );
    assert_eq!(
        worker.selection_model_paths(&request, &secondary).0,
        temp.path().join("models/secondary/model.onnx")
    );
    request.models_root = None;
    let secondary_paths = worker.selection_model_paths(&request, &secondary);
    assert!(secondary_paths.0.ends_with("secondary.onnx"));
    assert!(secondary_paths.1.ends_with("secondary.onnx.json"));
    assert_ne!(secondary_paths.0, request.piper_model.clone().unwrap());
    request.models_root = Some(temp.path().join("models"));
    request.piper_model = None;
    assert_eq!(
        worker.selection_model_paths(&request, &primary).1,
        request.piper_config.clone().unwrap()
    );
}

#[test]
fn missing_kokoro_cache_identity_does_not_block_healthy_primary_or_native_recovery() {
    use crate::tts_preferences::{TtsPreferences, TtsSelection};
    let temp = tempfile::tempdir().unwrap();
    let worker = ConversionWorker::new(AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temp.path().into(),
    )))
    .unwrap();
    let request = preference_test_request();
    let kokoro = TtsSelection {
        engine: "kokoro".into(),
        model_id: Some("kokoro-82m".into()),
        voice: None,
        session: Some(crate::tts_session::SessionSelection {
            version: 2,
            provider: "kokoro".into(),
            runtime: "kokoro".into(),
            model_id: Some("kokoro-82m".into()),
            model_revision: None,
            voice: None,
            options: Default::default(),
        }),
    };
    let edge = TtsSelection {
        engine: "edge".into(),
        model_id: None,
        voice: None,
        session: None,
    };
    let secondary = TtsPreferences {
        primary: edge,
        secondary: Some(kokoro.clone()),
        allow_online_fallback: false,
        policy_version: None,
    };
    assert!(worker
        .typed_cache_request_key(&request, &secondary, Some("en-US"), "source")
        .is_ok());
    let native = TtsPreferences {
        primary: kokoro.clone(),
        ..TtsPreferences::app_default(true)
    };
    assert!(worker
        .typed_cache_request_key(&request, &native, Some("en-US"), "source")
        .is_ok());
    let strict = TtsPreferences {
        primary: kokoro,
        secondary: None,
        allow_online_fallback: false,
        policy_version: None,
    };
    assert!(worker
        .typed_cache_request_key(&request, &strict, Some("en-US"), "source")
        .is_err());
}
