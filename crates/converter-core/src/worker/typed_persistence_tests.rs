    #[test]
    fn fallback_metadata_tracks_actual_role_when_primary_and_secondary_resolve_to_same_voice() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        for fail_primary in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let input = temp.path().join("book.epub");
            platform_test_book(&input);
            let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            ));
            let mut worker = ConversionWorker::new(config).unwrap();
            let attempts = Arc::new(AtomicUsize::new(0));
            let count = attempts.clone();
            worker.test_edge = Some(Arc::new(move |_| {
                if count.fetch_add(1, Ordering::AcqRel) == 0 && fail_primary {
                    Err(WorkerError::Edge(EdgeError::Timeout))
                } else {
                    Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
                }
            }));
            let mut request = preference_test_request();
            request.input = input;
            request.tts_preferences = Some(TtsPreferences {
                policy_version: None,
                primary: TtsSelection {
                    engine: "edge".into(),
                    model_id: None,
                    voice: Some("pt-BR-FranciscaNeural".into()),
                },
                secondary: Some(TtsSelection {
                    engine: "edge".into(),
                    model_id: None,
                    voice: None,
                }),
                allow_online_fallback: true,
            });
            let first = worker.run(request.clone()).unwrap();
            assert_eq!(first.fallback_used, fail_primary);
            assert_eq!(first.used_selections.len(), 1);
            assert_eq!(
                first.used_selections[0].voice.as_deref(),
                Some("pt-BR-FranciscaNeural")
            );
            let calls = attempts.load(Ordering::Acquire);
            worker.jobs.delete(&request.job_id).unwrap();
            let cached = worker.resume(request.clone()).unwrap();
            assert_eq!(cached.fallback_used, fail_primary);
            assert_eq!(
                attempts.load(Ordering::Acquire),
                calls,
                "cache must preserve actual role without synthesis"
            );
            let audio = worker
                .config
                .paths
                .output_dir
                .join(&request.job_id)
                .join(&cached.chapters[0].filename);
            let receipt_path = chapter_audio_receipt_path(&audio);
            let original_audio = fs::read(&audio).unwrap();
            let original_receipt = fs::read(&receipt_path).unwrap();
            let predecessor_state = fs::read(
                worker
                    .config
                    .paths
                    .jobs_dir
                    .join(format!("{}.json", request.job_id)),
            )
            .unwrap();
            let control = ConversionControl::default();
            control.set_recovery_job(&request.job_id).unwrap();
            let policy: crate::tts_preferences::SegmentPolicy =
                serde_json::from_value(serde_json::json!({"consecutive_failures": 2})).unwrap();
            worker = worker
                .with_control(control)
                .with_tts_policy_state(policy.clone());
            let mut successor_request = request.clone();
            successor_request.job_id = format!("recovered-{}", request.job_id);
            let recovered = worker.run(successor_request.clone()).unwrap();
            assert_eq!(
                attempts.load(Ordering::Acquire),
                calls,
                "recovery must not retry either provider"
            );
            assert_eq!(recovered.fallback_used, fail_primary);
            assert_eq!(recovered.used_selections, cached.used_selections);
            assert_eq!(recovered.tts_policy_state, Some(policy));
            let recovered_audio = worker
                .config
                .paths
                .output_dir
                .join(&successor_request.job_id)
                .join(&recovered.chapters[0].filename);
            assert_eq!(fs::read(&recovered_audio).unwrap(), original_audio);
            assert_eq!(
                fs::read(chapter_audio_receipt_path(&recovered_audio)).unwrap(),
                original_receipt
            );
            assert_eq!(fs::read(&audio).unwrap(), original_audio);
            assert_eq!(fs::read(&receipt_path).unwrap(), original_receipt);
            assert_eq!(
                fs::read(
                    worker
                        .config
                        .paths
                        .jobs_dir
                        .join(format!("{}.json", request.job_id))
                )
                .unwrap(),
                predecessor_state
            );
            let mut legacy: serde_json::Value = cache::read_json(&receipt_path).unwrap();
            let key = legacy["request_key"].as_str().unwrap().to_owned();
            legacy.as_object_mut().unwrap().remove("fallback_used");
            cache::atomic_write_json(receipt_path, &legacy).unwrap();
            assert!(
                !chapter_audio_is_complete(&audio, &key),
                "receipts without actual fallback metadata must not be reused"
            );
        }
    }

    #[test]
    fn typed_primary_success_persists_zero_before_resuming_after_another_failure() {
        use crate::tts_preferences::{SegmentPolicy, TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("recovered.epub");
        platform_test_book_with_text(&input, "Primário recuperado.");
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let state: SegmentPolicy =
            serde_json::from_value(serde_json::json!({"consecutive_failures":2})).unwrap();
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let worker = ConversionWorker::new(config.clone())
            .unwrap()
            .with_tts_policy_state(state)
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        let mut request = preference_test_request();
        request.input = input;
        request.job_id = "recovered-primary".into();
        request.tts_preferences = Some(TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
            },
            secondary: None,
            allow_online_fallback: false,
        });
        worker.run(request).unwrap();
        let persisted: serde_json::Value = cache::read_json(
            config
                .paths
                .output_dir
                .join("recovered-primary/manifest.json"),
        )
        .unwrap();
        assert_eq!(persisted["ttsPolicyState"]["consecutive_failures"], 0);
        let recovered: OutputManifest = serde_json::from_value(persisted).unwrap();
        let reset = recovered
            .tts_policy_state
            .expect("typed success must explicitly publish the reset");
        assert!(reset.is_initial());
        let next_input = temp.path().join("next.epub");
        platform_test_book_with_text(&next_input, "Um próximo segmento.");
        spoken.lock().unwrap().clear();
        let attempts = Arc::new(AtomicUsize::new(0));
        let recorded_attempts = Arc::clone(&attempts);
        let mut resumed = ConversionWorker::new(config)
            .unwrap()
            .with_tts_policy_state(reset)
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        resumed.test_edge = Some(Arc::new(move |_| {
            recorded_attempts.fetch_add(1, Ordering::Relaxed);
            Err(WorkerError::Edge(EdgeError::Timeout))
        }));
        let mut next = preference_test_request();
        next.input = next_input;
        next.job_id = "next-resumed".into();
        next.tts_preferences = Some(TtsPreferences {
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
        });
        let manifest = resumed.resume(next).unwrap();
        assert_eq!(attempts.load(Ordering::Relaxed), 1);
        assert_eq!(spoken.lock().unwrap().len(), 1);
        assert_eq!(manifest.used_selections.len(), 1);
        assert_eq!(manifest.used_selections[0].engine, "system");
        assert!(manifest.fallback_used);
        assert_eq!(
            serde_json::to_value(manifest).unwrap()["ttsPolicyState"]["consecutive_failures"],
            1
        );
    }

    #[test]
    fn typed_failure_policy_survives_separate_single_chapter_requests() {
        use crate::tts_preferences::{SegmentPolicy, TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let mut state = SegmentPolicy::default();
        let spoken = Arc::new(Mutex::new(Vec::new()));
        for chapter in 0..3 {
            let input = temp.path().join(format!("chapter-{chapter}.epub"));
            platform_test_book_with_text(&input, &format!("Unique chapter {chapter}."));
            let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
                std::iter::empty::<(String, String)>(),
                temp.path().to_path_buf(),
            ));
            let mut worker = ConversionWorker::new(config)
                .unwrap()
                .with_tts_policy_state(state)
                .with_platform_tts(Arc::new(TestSystem {
                    texts: spoken.clone(),
                }));
            worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Edge(EdgeError::Timeout))));
            let mut request = preference_test_request();
            request.input = input;
            request.job_id = format!("separate-chapter-{chapter}");
            request.tts_preferences = Some(TtsPreferences {
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
            });
            let result = worker.run(request);
            if chapter == 2 {
                assert!(result
                    .unwrap_err()
                    .to_string()
                    .contains("three consecutive"));
                assert_eq!(spoken.lock().unwrap().len(), 2);
                return;
            }
            let manifest = result.unwrap();
            let encoded = serde_json::to_value(&manifest).unwrap();
            assert_eq!(
                encoded["ttsPolicyState"]["consecutive_failures"],
                chapter + 1
            );
            state = serde_json::from_value(encoded["ttsPolicyState"].clone()).unwrap();
        }
        panic!("the third separate request must stop");
    }
