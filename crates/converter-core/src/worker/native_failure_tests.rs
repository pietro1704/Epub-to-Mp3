#[test]
fn persistent_edge_outage_fails_real_job_without_publishing_partial_audio() {
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("book.epub");
    platform_test_book_with_text(
        &input,
        &"Uma frase de teste sem conversão integral offline. ".repeat(40),
    );
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        temp.path().to_path_buf(),
    ));
    let output = config.paths.output_dir.join("outage-job");
    let spoken = Arc::new(Mutex::new(Vec::new()));
    let mut worker = ConversionWorker::new(config)
        .unwrap()
        .with_platform_tts(Arc::new(TestSystem {
            texts: Arc::clone(&spoken),
        }));
    worker.test_edge = Some(Arc::new(|_| Err(WorkerError::Edge(EdgeError::Timeout))));
    let request = ConversionRequest {
        tts_preferences: None,
        models_root: None,
        input,
        job_id: "outage-job".into(),
        engine: Some("edge".into()),
        voice: None,
        language: Some("pt-BR".into()),
        piper_model: None,
        piper_config: None,
        chapter_indices: None,
        no_parallel: true,
    };
    assert!(matches!(
        worker.run(request),
        Err(WorkerError::Synthesis(_))
    ));
    assert_eq!(
        worker.jobs.load("outage-job").unwrap().state,
        JobState::Failed
    );
    assert_eq!(
        worker.jobs.list().unwrap().len(),
        1,
        "Saved request options must not corrupt the job-record index"
    );
    assert_eq!(
        fs::read_dir(output).unwrap().count(),
        0,
        "Interrupted chapter cannot publish a partial MP3 or receipt"
    );
    assert!(!spoken.lock().unwrap().is_empty());
}

#[test]
fn invalid_system_wav_never_reaches_playback() {
    struct InvalidSystem;
    impl PlatformTts for InvalidSystem {
        fn synthesize_wav(
            &self,
            _: &str,
            _: &str,
            output: &Path,
            _: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), String> {
            fs::write(output, b"invalid").map_err(|e| e.to_string())
        }
    }
    let temp = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        temp.path().to_path_buf(),
    ));
    let worker = ConversionWorker::new(config)
        .unwrap()
        .with_platform_tts(Arc::new(InvalidSystem))
        .with_streaming_chunks(Arc::new(|_, _, _| {
            panic!("Invalid speech reached playback")
        }));
    assert!(matches!(
        synthesize_native_fixture(&worker, "system", "Text", &temp.path().join("audio.mp3")),
        Err(WorkerError::Synthesis(_))
    ));
}
#[test]
fn cancelled_worker_does_not_wait_for_busy_native_speech_lock() {
    let temp = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        temp.path().to_path_buf(),
    ));
    let spoken = Arc::new(Mutex::new(Vec::new()));
    let worker = ConversionWorker::new(config)
        .unwrap()
        .with_platform_tts(Arc::new(TestSystem {
            texts: Arc::clone(&spoken),
        }));
    let _busy = worker.platform_gate.lock().unwrap();
    let output = temp.path().join("audio.mp3");
    std::thread::scope(|scope| {
        let waiting = scope.spawn(|| synthesize_native_fixture(&worker, "system", "Text", &output));
        std::thread::sleep(std::time::Duration::from_millis(50));
        worker.cancel();
        let started = std::time::Instant::now();
        assert!(matches!(
            waiting.join().unwrap(),
            Err(WorkerError::Cancelled)
        ));
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
    });
    assert!(spoken.lock().unwrap().is_empty());
}

#[test]
fn platform_policy_has_a_distinct_cache_identity() {
    let edge = chapter_audio_request_key("book", "0", "Text", "edge", None, Some("pt-BR")).unwrap();
    let fallback =
        chapter_audio_request_key("book", "0", "Text", "edge+system-v2", None, Some("pt-BR"))
            .unwrap();
    assert_ne!(edge, fallback);
}

#[test]
fn token_cancellation_is_durable_and_preserves_job_store_errors() {
    struct CancelDuringSpeech {
        cancel: CancellationToken,
        jobs: ConversionJobStore,
        durable_request: bool,
        remove_record: bool,
        calls: Arc<AtomicUsize>,
    }
    impl PlatformTts for CancelDuringSpeech {
        fn synthesize_wav(
            &self,
            _: &str,
            _: &str,
            _: &Path,
            _: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), String> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            if self.remove_record {
                self.jobs.delete("cancelled-job").unwrap();
            } else if self.durable_request {
                self.jobs.request_cancellation("cancelled-job").unwrap();
            }
            self.cancel.cancel();
            Err("fixture cancellation".into())
        }
    }
    for (durable_request, remove_record) in [(false, false), (true, false), (false, true)] {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("book.epub");
        platform_test_book(&input);
        let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            temp.path().to_path_buf(),
        ));
        let worker = ConversionWorker::new(config).unwrap();
        let jobs = worker.jobs.clone();
        let cancel = worker.cancel.clone();
        let calls = Arc::new(AtomicUsize::new(0));
        let worker = worker.with_platform_tts(Arc::new(CancelDuringSpeech {
            cancel,
            jobs: jobs.clone(),
            durable_request,
            remove_record,
            calls: Arc::clone(&calls),
        }));
        let result = worker.run(ConversionRequest {
            tts_preferences: None,
            models_root: None,
            input,
            job_id: "cancelled-job".into(),
            engine: Some("system".into()),
            voice: None,
            language: Some("pt-BR".into()),
            piper_model: None,
            piper_config: None,
            chapter_indices: None,
            no_parallel: true,
        });
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        if remove_record {
            assert!(matches!(
                result,
                Err(WorkerError::Job(JobError::NotFound(_)))
            ));
        } else {
            assert!(matches!(result, Err(WorkerError::Cancelled)));
            assert_eq!(
                jobs.load("cancelled-job").unwrap().state,
                JobState::Cancelled
            );
        }
    }
}

#[test]
fn stale_playback_chunk_is_rejected_without_publishing_chapter_audio() {
    let control = ConversionControl::new();
    control.set_playback_window(0, 1);
    let accepted_chunks = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let accepted = Arc::clone(&accepted_chunks);
    let sink: VersionedStreamingChunkSink = Arc::new(move |_, _, _, _| {
        accepted.fetch_add(1, Ordering::AcqRel);
        true
    });
    let stale = std::sync::atomic::AtomicBool::new(false);

    assert!(
        playback_chunk_delivery::dispatch_playback_chunk_at_generation(
            Some(&control),
            Some(&sink),
            0,
            0,
            b"current",
            &stale,
            None,
        )
    );
    control.set_playback_window(5, 1);
    assert!(
        !playback_chunk_delivery::dispatch_playback_chunk_at_generation(
            Some(&control),
            Some(&sink),
            0,
            1,
            b"stale",
            &stale,
            None,
        )
    );
    control.set_playback_window(0, 1);
    control
        .set_listening_position(crate::tts_session::ListeningPosition {
            version: 2,
            chapter_index: 0,
            text_offset: 1,
        })
        .unwrap();
    assert!(
        !playback_chunk_delivery::dispatch_playback_chunk_at_generation(
            Some(&control),
            Some(&sink),
            0,
            0,
            b"manual",
            &stale,
            None,
        )
    );
    assert!(stale.load(Ordering::Acquire));
    assert_eq!(accepted_chunks.load(Ordering::Acquire), 1);

    let root = tempfile::tempdir().unwrap();
    let output = root.path().join("chapter.mp3");
    let result = ensure_chapter_audio(&output, "request-key", |_| {
        Err(WorkerError::PlaybackWindowChanged)
    });
    assert!(matches!(result, Err(WorkerError::PlaybackWindowChanged)));
    assert!(
        !output.exists(),
        "stale synthesis must not publish durable audio"
    );
}
