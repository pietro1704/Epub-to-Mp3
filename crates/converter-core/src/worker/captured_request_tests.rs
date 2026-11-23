use super::*;

#[test]
fn migrated_explicit_selection_is_idempotent_and_survives_default_changes() {
    let root = tempfile::tempdir().unwrap();
    let mut config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        root.path().into(),
    ));
    config.engine = "piper".into();
    let mut worker = ConversionWorker::new(config).unwrap();
    let mut legacy = preference_test_request();
    legacy.engine = Some("edge".into());
    legacy.voice = Some("pt-BR-FranciscaNeural".into());
    let serialized = serde_json::to_vec(&legacy).unwrap();
    let captured = worker
        .capture_request_preferences(serde_json::from_slice(&serialized).unwrap())
        .unwrap();
    let preferences = captured.tts_preferences.as_ref().unwrap();
    assert_eq!(preferences.primary.engine, "edge");
    assert_eq!(
        preferences.primary.voice.as_deref(),
        Some("pt-BR-FranciscaNeural")
    );
    assert!(preferences.secondary.is_none());
    // A legacy job that names Edge is itself the explicit online choice: it is
    // captured with the consent that Edge as a primary voice now requires.
    assert!(preferences.allow_online_fallback);
    worker.config.engine = "system".into();
    assert_eq!(
        worker
            .capture_request_preferences(captured.clone())
            .unwrap(),
        captured
    );
    assert_eq!(serde_json::to_vec(&legacy).unwrap(), serialized);
}

#[test]
fn failed_migration_keeps_saved_request_and_audio_untouched() {
    let root = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        root.path().into(),
    ));
    let mut request = preference_test_request();
    request.engine = Some("retired-engine".into());
    let path = persisted_request_path(&config.paths.jobs_dir, &request.job_id);
    cache::atomic_write_json(&path, &request).unwrap();
    let original = fs::read(&path).unwrap();
    let audio = config
        .paths
        .output_dir
        .join(&request.job_id)
        .join("existing.mp3");
    fs::create_dir_all(audio.parent().unwrap()).unwrap();
    fs::write(&audio, b"retained audio").unwrap();
    let worker = ConversionWorker::new(config).unwrap();
    assert!(worker.resume(cache::read_json(&path).unwrap()).is_err());
    assert_eq!(fs::read(path).unwrap(), original);
    assert_eq!(fs::read(audio).unwrap(), b"retained audio");
    assert!(worker.jobs.list().unwrap().is_empty());
}

#[test]
fn omitted_selection_captures_piper_and_recovers_locally_without_contacting_edge() {
    for engine in [None, Some("auto".to_owned())] {
        let root = tempfile::tempdir().unwrap();
        let input = root.path().join("book.epub");
        platform_test_book(&input);
        let mut config = AppConfig::from_paths(crate::paths::resolve_paths_from(
            std::iter::empty::<(String, String)>(),
            root.path().into(),
        ));
        config.engine = "auto".into();
        let jobs = config.paths.jobs_dir.clone();
        let spoken = Arc::new(Mutex::new(Vec::new()));
        let online_calls = Arc::new(AtomicUsize::new(0));
        let observed = online_calls.clone();
        let mut worker = ConversionWorker::new(config)
            .unwrap()
            .with_platform_tts(Arc::new(TestSystem {
                texts: spoken.clone(),
            }));
        worker.test_edge = Some(Arc::new(move |_| {
            observed.fetch_add(1, Ordering::Relaxed);
            Err(WorkerError::Edge(EdgeError::Timeout))
        }));
        let mut request = preference_test_request();
        request.input = input;
        request.engine = engine;
        let result = worker.run(request.clone());
        assert_eq!(
            online_calls.load(Ordering::Relaxed),
            0,
            "default conversion must stay offline"
        );
        let manifest = result.unwrap();
        let preferences = manifest.tts_preferences.unwrap();
        assert_eq!(
            preferences,
            crate::tts_preferences::TtsPreferences::app_default(true)
        );
        assert!(manifest.fallback_used);
        assert!(!spoken.lock().unwrap().is_empty());
        let saved: ConversionRequest =
            cache::read_json(persisted_request_path(&jobs, &request.job_id)).unwrap();
        assert_eq!(saved.tts_preferences, Some(preferences));
        let original = serde_json::to_value(&saved).unwrap();
        let again: ConversionRequest = serde_json::from_value(original.clone()).unwrap();
        assert_eq!(serde_json::to_value(again).unwrap(), original);
    }
}

#[test]
fn explicit_namespaced_model_preserves_model_identity_and_language_validation() {
    let root = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        root.path().into(),
    ));
    let worker = ConversionWorker::new(config).unwrap();
    for model in ["pt_BR-faber-medium.onnx", "pt_BR-faber-medium/model.onnx"] {
        let mut request = preference_test_request();
        request.engine = Some("piper".into());
        request.piper_model = Some(root.path().join(model));
        let captured = worker.capture_request_preferences(request.clone()).unwrap();
        let preferences = captured.tts_preferences.as_ref().unwrap();
        assert_eq!(
            preferences.primary.model_id.as_deref(),
            Some(crate::tts_preferences::FABER_MODEL_ID)
        );
        assert!(preferences.validate(Some("en-US")).is_err());
        assert_eq!(captured.piper_model, request.piper_model);
    }
}

#[test]
fn typed_request_identity_changes_with_model_or_config_contents_at_the_same_paths() {
    let root = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        root.path().into(),
    ));
    let worker = ConversionWorker::new(config).unwrap();
    let model = root.path().join("pt_BR-faber-medium.onnx");
    let model_config = model.with_extension("onnx.json");
    fs::write(&model, b"first model").unwrap();
    fs::write(&model_config, b"{}").unwrap();
    let mut request = preference_test_request();
    request.engine = Some("piper".into());
    request.piper_model = Some(model.clone());
    request.piper_config = Some(model_config.clone());
    let request = worker.capture_request_preferences(request).unwrap();
    let key = || {
        worker
            .typed_cache_request_key(
                &request,
                request.tts_preferences.as_ref().unwrap(),
                Some("pt-BR"),
                "same chapter",
            )
            .unwrap()
    };
    let original = key();
    fs::write(model, b"other model").unwrap();
    let changed_model = key();
    assert_ne!(original, changed_model);
    fs::write(model_config, b"{\"changed\":true}").unwrap();
    assert_ne!(changed_model, key());
}
