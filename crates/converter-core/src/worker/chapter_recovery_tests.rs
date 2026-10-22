    #[test]
    fn native_policy_reuses_pure_piper_but_rejects_opaque_native_receipts_and_recovery() {
        use crate::tts_preferences::TtsSelection;
        for native in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let source_dir = temp.path().join("source");
            let target_dir = temp.path().join("target");
            fs::create_dir_all(&source_dir).unwrap();
            fs::create_dir_all(&target_dir).unwrap();
            let source = source_dir.join("chapter.mp3");
            let selection = if native {
                TtsSelection {
                    engine: "system".into(),
                    model_id: None,
                    voice: None,
                }
            } else {
                TtsSelection::default()
            };
            ensure_chapter_audio(&source, "stable-v2-key", |pending| {
                fs::write(
                    pending,
                    platform_tts::encode_wav(&test_system_wav()).unwrap(),
                )?;
                cache::atomic_write_json(
                    pending.with_extension("tts-usage.json"),
                    &(vec![selection.clone()], native),
                )?;
                Ok(())
            })
            .unwrap();
            assert_eq!(
                chapter_audio_is_reusable(&source, "stable-v2-key", true),
                !native
            );
            assert!(chapter_audio_is_reusable(&source, "stable-v2-key", false));
            let target = target_dir.join("chapter.mp3");
            recover_chapter_audio_with_native_policy(
                temp.path(),
                "source",
                &target,
                "stable-v2-key",
                true,
                &|| Ok(()),
            )
            .unwrap();
            assert_eq!(target.exists(), !native);
            assert!(source.exists());
        }
    }
    #[test]
    fn app_policy_uses_short_system_passages_until_primary_recovers() {
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
            if edge_calls.fetch_add(1, Ordering::SeqCst) < 2 {
                Err(WorkerError::Edge(EdgeError::Timeout))
            } else {
                Ok(platform_tts::encode_wav(&test_system_wav()).unwrap())
            }
        }));
        let preferences = TtsPreferences {
            policy_version: Some(2),
            primary: TtsSelection {
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: Some(TtsSelection::default()),
            allow_online_fallback: false,
        };
        let providers = Mutex::new(Vec::new());
        worker
            .synthesize_preferences(
                &preference_test_request(),
                &preferences,
                &"Uma frase que continua após a recuperação. ".repeat(80),
                &temp.path().join("recovered.mp3"),
                0,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &providers,
                1,
            )
            .unwrap();
        let native = spoken.lock().unwrap();
        assert_eq!(
            native.len(),
            3,
            "One fallback passage between recovery probes"
        );
        assert!(native.iter().all(|text| text.chars().count() <= 240));
        assert!(calls.load(Ordering::SeqCst) >= 3);
        assert!(worker.segment_policy.lock().unwrap().is_initial());
        let used = providers.into_inner().unwrap();
        assert!(used.iter().any(|selection| selection.engine == "system"));
        assert!(used.iter().any(|selection| selection.engine == "edge"));
    }
    #[test]
    fn worker_reuses_proven_audio_and_publishes_the_matching_archive() {
        let root = tempfile::tempdir().unwrap();
        let paths = crate::paths::resolve_paths_from(
            std::collections::HashMap::<String, String>::new(),
            root.path().to_path_buf(),
        );
        let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
        let input = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../web/public/sample.epub");
        let source = fs::read(&input).unwrap();
        let book = epub::parse_epub(std::io::Cursor::new(&source)).unwrap();
        assert!(book.cover.is_none());
        assert_eq!(
            book.chapters.len(),
            2,
            "fixture must retain a larger source domain"
        );
        let chapter = &book.chapters[0];
        let output = worker.config.paths.output_dir.join("proven-existing-audio");
        let audio = output.join(format!("0001-{}.mp3", sanitize(&chapter.name)));
        let key = chapter_audio_request_key(
            &cache::sha256_bytes(&source),
            &chapter.index,
            &chapter.text,
            "piper",
            None,
            Some("en"),
        )
        .unwrap();
        ensure_chapter_audio(&audio, &key, |pending| {
            fs::write(pending, b"completed synthesis")?;
            Ok(())
        })
        .unwrap();
        let cached_text = worker
            .config
            .paths
            .cache_dir
            .join(cache::sha256_bytes(&source))
            .join(format!("{}.json", chapter.index.replace('.', "_")));
        cache::atomic_write_json(&cached_text, &"x".repeat(chapter.text.chars().count())).unwrap();

        let request = ConversionRequest {
            tts_preferences: None,
            models_root: None,
            input,
            job_id: "proven-existing-audio".into(),
            engine: Some("piper".into()),
            voice: None,
            language: Some("en".into()),
            piper_model: None,
            piper_config: None,
            chapter_indices: Some(vec!["0".into()]),
            no_parallel: true,
        };
        let manifest = worker.run(request.clone()).unwrap();
        assert_eq!(
            cache::read_json::<String>(&cached_text).unwrap(),
            chapter.text
        );
        assert_eq!(manifest.chapters.len(), 1);
        assert_eq!(manifest.chapters[0].source_index, 0);
        assert_eq!(manifest.source_chapters_total, Some(2));
        let persisted: OutputManifest = cache::read_json(output.join("manifest.json")).unwrap();
        assert_eq!(persisted.source_chapters_total, Some(2));
        assert_eq!(persisted.chapters.len(), 1);
        assert_eq!(persisted.chapters[0].source_index, 0);
        assert_eq!(
            worker.jobs.load("proven-existing-audio").unwrap().state,
            JobState::Completed
        );
        assert!(chapter_audio_is_complete(&audio, &key));
        let mut archive =
            zip::ZipArchive::new(fs::File::open(output.join(manifest.archive)).unwrap()).unwrap();
        let mut entry = archive.by_name(&manifest.chapters[0].filename).unwrap();
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(&mut entry, &mut bytes).unwrap();
        assert_eq!(bytes, b"completed synthesis");
        let changed_output = worker.config.paths.output_dir.join("changed-option-audio");
        fs::create_dir_all(&changed_output).unwrap();
        let changed_audio = changed_output.join(audio.file_name().unwrap());
        fs::copy(&audio, &changed_audio).unwrap();
        fs::copy(
            chapter_audio_receipt_path(&audio),
            chapter_audio_receipt_path(&changed_audio),
        )
        .unwrap();
        assert!(worker
            .run(ConversionRequest {
                tts_preferences: None,
                models_root: None,
                job_id: "changed-option-audio".into(),
                voice: Some("different-voice".into()),
                ..request
            })
            .is_err());
        assert_eq!(
            worker.jobs.load("changed-option-audio").unwrap().state,
            JobState::Failed
        );
        assert!(chapter_audio_is_complete(&changed_audio, &key));
        assert!(chapter_audio_is_complete(&audio, &key));
    }
    #[test]
    fn recovery_cancelled_after_staging_does_not_publish_artifacts() {
        let root = tempfile::tempdir().unwrap();
        let predecessor = root.path().join("predecessor");
        let successor = root.path().join("successor");
        fs::create_dir_all(&predecessor).unwrap();
        fs::create_dir_all(&successor).unwrap();
        let source = predecessor.join("chapter.mp3");
        let output = successor.join("chapter.mp3");
        ensure_chapter_audio(&source, "recovery-cancel", |pending| {
            fs::write(
                pending,
                platform_tts::encode_wav(&test_system_wav()).unwrap(),
            )?;
            Ok(())
        })
        .unwrap();
        let source_bytes = fs::read(&source).unwrap();
        let source_receipt = fs::read(chapter_audio_receipt_path(&source)).unwrap();
        let checks = std::cell::Cell::new(0);
        let result = recover_chapter_audio(
            root.path(),
            "predecessor",
            &output,
            "recovery-cancel",
            &|| {
                checks.set(checks.get() + 1);
                if checks.get() == 2 {
                    let staging = fs::read_dir(&successor)
                        .unwrap()
                        .next()
                        .unwrap()
                        .unwrap()
                        .path();
                    assert!(staging
                        .file_name()
                        .unwrap()
                        .to_string_lossy()
                        .starts_with(".chapter-recovery-"));
                    assert_eq!(fs::read(staging.join("chapter.mp3")).unwrap(), source_bytes);
                    assert_eq!(
                        fs::read(staging.join("chapter.mp3.complete.json")).unwrap(),
                        source_receipt
                    );
                    return Err(WorkerError::Cancelled);
                }
                Ok(())
            },
        );
        assert!(matches!(result, Err(WorkerError::Cancelled)));
        assert_eq!(checks.get(), 2);
        assert!(!output.exists());
        assert!(!chapter_audio_receipt_path(&output).exists());
        assert_eq!(fs::read_dir(&successor).unwrap().count(), 0);
        assert_eq!(fs::read(&source).unwrap(), source_bytes);
        assert_eq!(
            fs::read(chapter_audio_receipt_path(&source)).unwrap(),
            source_receipt
        );
    }

    #[test]
    fn recovered_cache_cancellation_never_announces_a_completed_chapter() {
        use crate::tts_preferences::{TtsPreferences, TtsSelection};
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("book.epub");
        platform_test_book(&input);
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let predecessor = ConversionWorker::new(config.clone())
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        let mut request = preference_test_request();
        request.input = input;
        request.job_id = "cancel-predecessor".into();
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
        let original = predecessor.run(request.clone()).unwrap();
        let original_directory = config.paths.output_dir.join(&request.job_id);
        let source = original_directory.join(&original.chapters[0].filename);
        let source_bytes = fs::read(&source).unwrap();
        let source_receipt = fs::read(chapter_audio_receipt_path(&source)).unwrap();
        let source_state = fs::read(config.paths.jobs_dir.join("cancel-predecessor.json")).unwrap();
        let source_manifest = fs::read(original_directory.join("manifest.json")).unwrap();
        let speech_count = spoken.lock().unwrap().len();
        let control = ConversionControl::default();
        control.set_recovery_job(&request.job_id).unwrap();
        let cancel = CancellationToken::default();
        let stop = cancel.clone();
        let completions = Arc::new(AtomicUsize::new(0));
        let observed = completions.clone();
        let successor = ConversionWorker::new(config.clone())
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }))
            .with_control(control)
            .with_cancellation(cancel)
            .with_progress(Arc::new(move |event| {
                if event.message.starts_with("Playing cached audio") {
                    stop.cancel();
                }
            }))
            .with_chapter_completed(Arc::new(move |_| {
                observed.fetch_add(1, Ordering::AcqRel);
            }));
        request.job_id = "cancel-successor".into();
        assert!(matches!(
            successor.run(request),
            Err(WorkerError::Cancelled)
        ));
        assert_eq!(
            successor.jobs.load("cancel-successor").unwrap().state,
            JobState::Cancelled
        );
        assert_eq!(completions.load(Ordering::Acquire), 0);
        assert_eq!(spoken.lock().unwrap().len(), speech_count);
        assert!(!config
            .paths
            .output_dir
            .join("cancel-successor/manifest.json")
            .exists());
        assert_eq!(fs::read(&source).unwrap(), source_bytes);
        assert_eq!(
            fs::read(chapter_audio_receipt_path(&source)).unwrap(),
            source_receipt
        );
        assert_eq!(
            fs::read(config.paths.jobs_dir.join("cancel-predecessor.json")).unwrap(),
            source_state
        );
        assert_eq!(
            fs::read(original_directory.join("manifest.json")).unwrap(),
            source_manifest
        );
    }
