    #[test]
    fn explicit_preferences_retry_primary_after_invalid_audio_and_publish_mixed_segments() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            Vec::<(String, String)>::new(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        let attempts = Arc::new(AtomicUsize::new(0));
        let count = attempts.clone();
        worker.test_edge = Some(Arc::new(move |_| {
            if count.fetch_add(1, Ordering::AcqRel) == 0 {
                Ok(b"malformed primary MP3".to_vec())
            } else {
                Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
            }
        }));
        let preferences = TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: Some("pt-BR-FranciscaNeural".into()),
            },
            secondary: Some(TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
            }),
            allow_online_fallback: false,
        };
        let text = "A sentence for voice selection. ".repeat(40);
        let providers = Mutex::new(Vec::new());
        let out = temp.path().join("mixed.mp3");
        worker
            .synthesize_preferences(
                &preference_test_request(),
                &preferences,
                &text,
                &out,
                0,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &providers,
                1,
            )
            .unwrap();
        assert!(attempts.load(Ordering::Acquire) > 1);
        assert_eq!(spoken.lock().unwrap().len(), 1);
        assert_eq!(
            providers
                .lock()
                .unwrap()
                .iter()
                .map(|s| s.engine.as_str())
                .collect::<Vec<_>>(),
            vec!["system", "edge"]
        );
        platform_tts::validate_mp3(&fs::read(out).unwrap()).unwrap();
    }
    #[test]
    fn strict_preferences_do_not_use_registered_system_fallback() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            Vec::<(String, String)>::new(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        worker.test_edge = Some(Arc::new(|_| {
            Err(WorkerError::Piper("fixture voice failed".into()))
        }));
        let preferences = TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: None,
            allow_online_fallback: false,
        };
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            "A sentence.",
            &temp.path().join("strict.mp3"),
            0,
            Some("pt"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
        );
        let error = result.unwrap_err().to_string();
        assert!(error.contains("no secondary voice is enabled"));
        assert!(error.contains("fixture voice failed"));
        assert!(spoken.lock().unwrap().is_empty());
    }
