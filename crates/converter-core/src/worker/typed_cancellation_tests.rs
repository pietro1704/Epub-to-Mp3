    #[test]
    fn in_flight_native_cancellation_and_stale_results_do_not_commit_policy() {
        struct InterruptedSystem {
            cancel: CancellationToken,
            stale: Arc<std::sync::atomic::AtomicBool>,
            mark_stale: bool,
        }
        impl PlatformTts for InterruptedSystem {
            fn synthesize_wav(
                &self,
                _: &str,
                _: &str,
                output: &Path,
                _: &(dyn Fn() -> bool + Sync),
            ) -> Result<(), String> {
                fs::write(output, test_system_wav()).unwrap();
                if self.mark_stale {
                    self.stale.store(true, Ordering::Release);
                } else {
                    self.cancel.cancel();
                }
                Err("native operation interrupted in flight".into())
            }
        }
        for cooldown in [false, true] {
            for mark_stale in [false, true] {
                let temp = tempfile::tempdir().unwrap();
                let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
                    std::iter::empty::<(String, String)>(),
                    temp.path().to_path_buf(),
                ));
                let initial: crate::tts_preferences::SegmentPolicy = if cooldown {
                    serde_json::from_value(
                        serde_json::json!({"consecutive_failures":2,"recovery_remaining":5}),
                    )
                    .unwrap()
                } else {
                    Default::default()
                };
                let stale = Arc::new(std::sync::atomic::AtomicBool::new(false));
                let mut worker = ConversionWorker::new(config)
                    .unwrap()
                    .with_tts_policy_state(initial.clone());
                let cancel = worker.cancel.clone();
                worker = worker.with_platform_tts(Arc::new(InterruptedSystem {
                    cancel,
                    stale: stale.clone(),
                    mark_stale,
                }));
                let result = worker.synthesize_preferences(
                    &preference_test_request(),
                    &crate::tts_preferences::TtsPreferences::app_default(true),
                    "Uma frase curta.",
                    &temp.path().join("interrupted.mp3"),
                    0,
                    Some("pt-BR"),
                    &stale,
                    &Mutex::new(Vec::new()),
                    1,
                );
                if mark_stale {
                    assert!(matches!(result, Err(WorkerError::PlaybackWindowChanged)));
                } else {
                    assert!(matches!(result, Err(WorkerError::Cancelled)));
                }
                assert_eq!(*worker.segment_policy.lock().unwrap(), initial);
                assert!(worker.fallback_chapters.lock().unwrap().is_empty());
            }
        }
    }
    #[test]
    fn typed_playback_window_change_does_not_count_as_provider_failure() {
        let temp = tempfile::tempdir().unwrap();
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let mut worker = ConversionWorker::new(config).unwrap();
        let stale = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let changed = stale.clone();
        worker.test_edge = Some(Arc::new(move |_| {
            changed.store(true, Ordering::Release);
            Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
        }));
        let mut preferences = crate::tts_preferences::TtsPreferences::default();
        preferences.primary.engine = "edge".into();
        preferences.primary.model_id = None;
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            "Uma frase curta.",
            &temp.path().join("stale.mp3"),
            0,
            Some("pt-BR"),
            &stale,
            &Mutex::new(Vec::new()),
            1,
        );
        assert!(matches!(result, Err(WorkerError::PlaybackWindowChanged)));
        assert_eq!(
            serde_json::to_value(worker.segment_policy.lock().unwrap().clone()).unwrap()
                ["consecutive_failures"],
            0
        );
    }

    #[test]
    fn typed_provider_returning_audio_after_cancellation_never_publishes_or_falls_back() {
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
        let cancel = worker.cancel.clone();
        worker.test_edge = Some(Arc::new(move |_| {
            cancel.cancel();
            Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
        }));
        worker = worker.with_streaming_chunks(Arc::new(|_, _, _| {
            panic!("cancelled audio must not be delivered")
        }));
        let preferences = TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: Some(TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
            }),
            allow_online_fallback: false,
        };
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            "Uma frase curta.",
            &temp.path().join("cancelled.mp3"),
            0,
            Some("pt-BR"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
        );
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert!(spoken.lock().unwrap().is_empty());
    }

    #[test]
    fn typed_policy_stops_third_failure_and_cancellation_never_falls_back() {
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
        worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Edge(EdgeError::Timeout))));
        let preferences = TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: Some(TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
            }),
            allow_online_fallback: false,
        };
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            &"A sentence. ".repeat(300),
            &temp.path().join("outage.mp3"),
            0,
            Some("pt-BR"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
        );
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("three consecutive"));
        assert_eq!(spoken.lock().unwrap().len(), 2);
        spoken.lock().unwrap().clear();
        worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Cancelled)));
        let result = worker.synthesize_preferences(
            &preference_test_request(),
            &preferences,
            "A sentence.",
            &temp.path().join("cancel.mp3"),
            0,
            Some("pt-BR"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
        );
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert!(spoken.lock().unwrap().is_empty());
    }
