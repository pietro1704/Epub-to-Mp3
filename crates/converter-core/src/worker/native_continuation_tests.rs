    #[test]
    fn missing_piper_continues_native_beyond_three_segments_and_cancellation_stops() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        let preferences = crate::tts_preferences::TtsPreferences::app_default(true);
        let text = "Uma frase com ação e coração. ".repeat(130);
        let out = temp.path().join("native-fallback.mp3");
        worker
            .synthesize_preferences(
                &preference_test_request(),
                &preferences,
                &text,
                &out,
                0,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &Mutex::new(Vec::new()),
                1,
            )
            .unwrap();
        assert!(spoken.lock().unwrap().len() > 3);
        platform_tts::validate_mp3(&fs::read(out).unwrap()).unwrap();
        let snapshot = worker.segment_policy.lock().unwrap().clone();
        worker.cancel.cancel();
        let count = spoken.lock().unwrap().len();
        assert!(matches!(
            worker.synthesize_preferences(
                &preference_test_request(),
                &preferences,
                "Outra frase.",
                &temp.path().join("cancelled.mp3"),
                0,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &Mutex::new(Vec::new()),
                1
            ),
            Err(WorkerError::Cancelled)
        ));
        assert_eq!(spoken.lock().unwrap().len(), count);
        assert_eq!(*worker.segment_policy.lock().unwrap(), snapshot);
    }

    #[test]
    fn app_policy_uses_configured_secondary_before_system_voice() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        let calls = Arc::new(AtomicUsize::new(0));
        let edge_calls = calls.clone();
        worker.test_edge = Some(Arc::new(move |_| {
            edge_calls.fetch_add(1, Ordering::SeqCst);
            Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
        }));
        let preferences = TtsPreferences {
            secondary: Some(TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: Some("pt-BR-FranciscaNeural".into()),
            }),
            allow_online_fallback: true,
            ..TtsPreferences::app_default(true)
        };
        let providers = Mutex::new(Vec::new());
        worker
            .synthesize_preferences(
                &preference_test_request(),
                &preferences,
                &"Uma frase para a voz secundária. ".repeat(80),
                &temp.path().join("secondary.mp3"),
                0,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &providers,
                1,
            )
            .unwrap();
        assert!(calls.load(Ordering::SeqCst) > 3);
        assert!(spoken.lock().unwrap().is_empty());
        assert_eq!(
            providers.into_inner().unwrap(),
            vec![preferences.secondary.unwrap()]
        );
    }

    #[test]
    fn app_policy_rate_limited_primary_waits_while_native_continues() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        let calls = Arc::new(AtomicUsize::new(0));
        let edge_calls = calls.clone();
        worker.test_edge = Some(Arc::new(move |_| {
            edge_calls.fetch_add(1, Ordering::SeqCst);
            Err(WorkerError::Edge(EdgeError::RateLimited {
                status: 429,
                retry_after: Some(std::time::Duration::from_secs(60)),
            }))
        }));
        let preferences = TtsPreferences {
            policy_version: Some(2),
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: None,
            allow_online_fallback: false,
        };
        worker
            .synthesize_preferences(
                &preference_test_request(),
                &preferences,
                &"Uma passagem para a voz instalada. ".repeat(80),
                &temp.path().join("throttled.mp3"),
                0,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &Mutex::new(Vec::new()),
                1,
            )
            .unwrap();
        assert!(spoken.lock().unwrap().len() > 3);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "Retry-After must prevent extra provider probes"
        );
    }
    #[test]
    fn incompatible_book_language_keeps_piper_configured_and_uses_native_only_when_enabled() {
        use crate::tts_preferences::TtsPreferences;
        struct LanguageRecorder(Arc<Mutex<Vec<String>>>);
        impl PlatformTts for LanguageRecorder {
            fn synthesize_wav(
                &self,
                _: &str,
                language: &str,
                output: &Path,
                _: &(dyn Fn() -> bool + Sync),
            ) -> Result<(), String> {
                self.0.lock().unwrap().push(language.into());
                fs::write(output, test_system_wav()).map_err(|error| error.to_string())
            }
        }
        for language in ["en", "en-US"] {
            let app = TtsPreferences::app_default(true);
            let mut legacy = app.clone();
            legacy.policy_version = None;
            for (preferences, uses_native) in [
                (app.clone(), true),
                (legacy, false),
                (app.effective_selection(None, false), false),
                (TtsPreferences::app_default(false), false),
            ] {
                let temp = tempfile::tempdir().unwrap();
                let input = temp.path().join("english.epub");
                platform_test_book_in_language(&input, "A short English sentence.", language);
                let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
                    std::iter::empty::<(String, String)>(),
                    temp.path().to_path_buf(),
                ));
                let output = config.paths.output_dir.join("english");
                let spoken = Arc::new(Mutex::new(Vec::new()));
                let worker = ConversionWorker::new(config)
                    .unwrap()
                    .with_platform_tts(Arc::new(LanguageRecorder(Arc::clone(&spoken))));
                let mut request = preference_test_request();
                request.input = input;
                request.job_id = "english".into();
                request.language = None;
                request.tts_preferences = Some(preferences.clone());
                let result = worker.run(request);
                if uses_native {
                    let manifest = result.unwrap();
                    assert_eq!(manifest.tts_preferences, Some(preferences));
                    assert!(manifest.fallback_used);
                    assert!(!manifest.used_selections.is_empty());
                    assert!(manifest
                        .used_selections
                        .iter()
                        .all(|voice| voice.engine == "system"));
                    let audio = fs::read(output.join(&manifest.chapters[0].filename)).unwrap();
                    assert!(platform_tts::validate_mp3(&audio).is_ok());
                    let spoken = spoken.lock().unwrap();
                    assert!(!spoken.is_empty());
                    assert!(spoken.iter().all(|actual| actual == language));
                } else {
                    assert!(result
                        .unwrap_err()
                        .to_string()
                        .contains("supports Portuguese"));
                    assert!(spoken.lock().unwrap().is_empty());
                    assert!(!output.join("manifest.json").exists());
                }
            }
        }
    }
