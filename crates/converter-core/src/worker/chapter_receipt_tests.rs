#[test]
fn forced_replacement_preserves_audio_and_receipt_on_failure_or_cancellation() {
    let fixture = tempfile::tempdir().unwrap();
    let output = fixture.path().join("selected.mp3");
    ensure_chapter_audio(&output, "identity", |pending| {
        fs::write(pending, test_system_wav())?;
        Ok(())
    })
    .unwrap();
    let prior = fs::read(&output).unwrap();
    let receipt = fs::read(chapter_audio_receipt_path(&output)).unwrap();
    for cancel in [false, true] {
        let result = ensure_chapter_audio_with_options(&output, "identity", true, |pending| {
            fs::write(pending, b"partial invalid audio")?;
            if cancel {
                Err(WorkerError::Cancelled)
            } else {
                Ok(())
            }
        });
        assert!(result.is_err());
        assert_eq!(fs::read(&output).unwrap(), prior);
        assert_eq!(
            fs::read(chapter_audio_receipt_path(&output)).unwrap(),
            receipt
        );
    }
    ensure_chapter_audio_with_options(&output, "identity", true, |pending| {
        fs::write(pending, test_system_wav_at_rate(16_000))?;
        Ok(())
    })
    .unwrap();
    assert_ne!(fs::read(&output).unwrap(), prior);
    assert!(chapter_audio_is_complete(&output, "identity"));
    assert_eq!(fs::read_dir(fixture.path()).unwrap().count(), 2);
}

#[test]
fn platform_fallback_actual_worker_publishes_receipt_and_reports_cached_voice() {
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("book.epub");
    platform_test_book(&input);
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        temp.path().to_path_buf(),
    ));
    let output_dir = config.paths.output_dir.join("system-job");
    let spoken = Arc::new(Mutex::new(Vec::new()));
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&events);
    let mut worker = ConversionWorker::new(config)
        .unwrap()
        .with_platform_tts(Arc::new(TestSystem {
            texts: Arc::clone(&spoken),
        }))
        .with_progress(Arc::new(move |event| sink.lock().unwrap().push(event)));
    worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Edge(EdgeError::Timeout))));
    let request = ConversionRequest {
        tts_preferences: None,
        models_root: None,
        input,
        job_id: "system-job".into(),
        engine: Some("edge".into()),
        voice: None,
        language: Some("pt-BR".into()),
        piper_model: None,
        piper_config: None,
        chapter_indices: None,
        no_parallel: true,
    };
    let manifest = worker.run(request.clone()).unwrap();
    assert_eq!(manifest.chapters.len(), 1);
    let audio = output_dir.join(&manifest.chapters[0].filename);
    assert!(platform_tts::validate_mp3(&fs::read(&audio).unwrap()).is_ok());
    let receipt: ChapterAudioReceipt =
        cache::read_json(chapter_audio_receipt_path(&audio)).unwrap();
    assert_eq!(receipt.provider.as_deref(), Some("system"));
    let calls = spoken.lock().unwrap().len();
    // A missing job record still permits recovery of durable chapter artifacts.
    worker.jobs.delete(&request.job_id).unwrap();
    worker.resume(request).unwrap();
    assert_eq!(spoken.lock().unwrap().len(), calls);
    assert!(
        events
            .lock()
            .unwrap()
            .iter()
            .any(|event| event.engine.as_deref() == Some("system")
                && event.message.contains("cached"))
    );
}
#[test]
fn empty_existing_audio_is_not_a_completed_chapter() {
    let root = tempfile::tempdir().unwrap();
    let audio = root.path().join("chapter.mp3");
    fs::write(&audio, []).unwrap();
    ensure_chapter_audio(&audio, "request", |pending| {
        fs::write(pending, b"completed synthesis")?;
        Ok(())
    })
    .unwrap();
    assert_eq!(fs::read(audio).unwrap(), b"completed synthesis");
}

#[test]
fn completed_audio_is_reused_only_for_the_same_request_and_content() {
    let root = tempfile::tempdir().unwrap();
    let audio = root.path().join("chapter.mp3");
    ensure_chapter_audio(&audio, "voice-one", |pending| {
        fs::write(pending, b"original")?;
        Ok(())
    })
    .unwrap();
    ensure_chapter_audio(&audio, "voice-one", |_| {
        panic!("valid audio must be reused")
    })
    .unwrap();
    assert!(!chapter_audio_is_complete(&audio, "voice-two"));
    // Equal-length corruption must not pass a size-only integrity check.
    fs::write(&audio, b"modified").unwrap();
    assert!(!chapter_audio_is_complete(&audio, "voice-one"));
    ensure_chapter_audio(&audio, "voice-one", |pending| {
        fs::write(pending, b"repaired")?;
        Ok(())
    })
    .unwrap();
    assert!(chapter_audio_is_complete(&audio, "voice-one"));
}

#[test]
fn failed_audio_attempt_preserves_previous_audio_and_cleans_staging() {
    let root = tempfile::tempdir().unwrap();
    let audio = root.path().join("chapter.mp3");
    ensure_chapter_audio(&audio, "old-request", |pending| {
        fs::write(pending, b"original")?;
        Ok(())
    })
    .unwrap();
    let result = ensure_chapter_audio(&audio, "new-request", |pending| {
        fs::write(pending, b"partial")?;
        Err(WorkerError::Cancelled)
    });
    assert!(matches!(result, Err(WorkerError::Cancelled)));
    assert_eq!(fs::read(&audio).unwrap(), b"original");
    assert!(chapter_audio_is_complete(&audio, "old-request"));
    assert!(!chapter_audio_is_complete(&audio, "new-request"));
    assert!(fs::read_dir(root.path())
        .unwrap()
        .all(|entry| !entry.unwrap().path().is_dir()));
}

#[test]
fn chapter_receipt_publishes_actual_tts_usage_atomically() {
    use crate::tts_preferences::TtsSelection;
    let temp = tempfile::tempdir().unwrap();
    let audio = temp.path().join("chapter.mp3");
    // Primary and automatic secondary can resolve to the same voice. The
    // role must come from synthesis, not be inferred from this selection.
    let selection = TtsSelection {
        session: None,
        engine: "edge".into(),
        model_id: None,
        voice: Some("pt-BR-FranciscaNeural".into()),
    };
    for fallback_used in [false, true] {
        let key = format!("same-voice-{fallback_used}");
        ensure_chapter_audio(&audio, &key, |pending| {
            fs::write(
                pending,
                platform_tts::encode_wav(&test_system_wav()).unwrap(),
            )?;
            cache::atomic_write_json(
                pending.with_extension("tts-usage.json"),
                &(vec![selection.clone()], fallback_used),
            )?;
            Ok(())
        })
        .unwrap();
        // Simulate interruption immediately after ensure returns: the outer
        // worker has not had a chance to rewrite or finalize metadata.
        let receipt: ChapterAudioReceipt =
            cache::read_json(chapter_audio_receipt_path(&audio)).unwrap();
        assert_eq!(receipt.used_selections, vec![selection.clone()]);
        assert_eq!(receipt.fallback_used, fallback_used);
        assert!(chapter_audio_is_complete(&audio, &key));
    }
}

#[test]
fn empty_synthesis_does_not_publish_audio_or_a_receipt() {
    let root = tempfile::tempdir().unwrap();
    let audio = root.path().join("chapter.mp3");
    let result = ensure_chapter_audio(&audio, "request", |pending| {
        fs::write(pending, [])?;
        Ok(())
    });
    assert!(matches!(
        result,
        Err(WorkerError::Audio(audio::AudioError::Validation(_)))
    ));
    assert!(!audio.exists());
    assert!(!chapter_audio_receipt_path(&audio).exists());
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
}

#[test]
fn unmarked_audio_is_regenerated_and_cover_changes_refresh_integrity() {
    let root = tempfile::tempdir().unwrap();
    let audio = root.path().join("chapter.mp3");
    fs::write(&audio, b"unproven old artifact").unwrap();
    ensure_chapter_audio(&audio, "request", |pending| {
        fs::write(pending, b"complete")?;
        Ok(())
    })
    .unwrap();
    fs::write(&audio, b"complete with new cover tags").unwrap();
    assert!(!chapter_audio_is_complete(&audio, "request"));
    refresh_chapter_audio_receipt(&audio).unwrap();
    assert!(chapter_audio_is_complete(&audio, "request"));
    fs::write(chapter_audio_receipt_path(&audio), b"broken metadata").unwrap();
    assert!(!chapter_audio_is_complete(&audio, "request"));
}

#[test]
fn worker_rejects_empty_audio_instead_of_completing_the_job() {
    let root = tempfile::tempdir().unwrap();
    let paths = crate::paths::resolve_paths_from(
        std::collections::HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    );
    let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
    let input = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../web/public/sample.epub");
    let book = epub::parse_epub(std::io::Cursor::new(fs::read(&input).unwrap())).unwrap();
    assert!(book.cover.is_none());
    let output = worker.config.paths.output_dir.join("empty-existing-audio");
    fs::create_dir_all(&output).unwrap();
    let audio = output.join(format!("0001-{}.mp3", sanitize(&book.chapters[0].name)));
    fs::write(&audio, []).unwrap();
    let result = worker.run(ConversionRequest {
        tts_preferences: None,
        models_root: None,
        input,
        job_id: "empty-existing-audio".into(),
        engine: Some("piper".into()),
        voice: None,
        language: Some("en".into()),
        piper_model: None,
        piper_config: None,
        chapter_indices: Some(vec!["0".into()]),
        no_parallel: true,
    });
    assert!(result.is_err(), "an empty MP3 must not complete a job");
    assert_eq!(
        worker.jobs.load("empty-existing-audio").unwrap().state,
        JobState::Failed
    );
    assert!(!output.join("manifest.json").exists());
    assert_eq!(fs::metadata(audio).unwrap().len(), 0);
}
