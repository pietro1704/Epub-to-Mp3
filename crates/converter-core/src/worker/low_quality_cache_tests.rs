use super::*;

#[test]
fn legacy_low_quality_audio_is_not_reused_from_current_job_cache() {
    verify_rejected_legacy_low_cache(false, false);
}

#[test]
fn legacy_low_quality_audio_is_not_imported_from_recovery_job() {
    verify_rejected_legacy_low_cache(true, false);
}

#[test]
fn typed_low_quality_audio_is_not_reused_from_current_job_cache() {
    verify_rejected_legacy_low_cache(false, true);
}

#[test]
fn typed_low_quality_audio_is_not_imported_from_recovery_job() {
    verify_rejected_legacy_low_cache(true, true);
}

fn verify_rejected_legacy_low_cache(recover: bool, typed: bool) {
    let root = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        root.path().to_path_buf(),
    ));
    let input = root.path().join("english.epub");
    platform_test_book_in_language(&input, "A known English sentence.", "en");
    let source = fs::read(&input).unwrap();
    let book = epub::parse_epub(std::io::Cursor::new(&source)).unwrap();
    let chapter = &book.chapters[0];
    let model = root.path().join(if typed {
        "custom-medium.onnx"
    } else {
        "en_US-lessac-low.onnx"
    });
    let voice_config = root.path().join("voice.json");
    fs::write(&model, b"preserved model").unwrap();
    fs::write(&voice_config, br#"{"audio":{"quality":"low"}}"#).unwrap();
    // Reproduce the exact legacy key used before the product quality policy.
    let identity = format!(
        "piper:{model:?}:{voice_config:?}:{}:{}",
        cache::sha256_file(&model).unwrap(),
        cache::sha256_file(&voice_config).unwrap()
    );
    let base_key = chapter_audio_request_key(
        &cache::sha256_bytes(&source),
        &chapter.index,
        &chapter.text,
        if typed { "piper" } else { &identity },
        None,
        Some("en"),
    )
    .unwrap();
    let preferences = typed.then(|| crate::tts_preferences::TtsPreferences {
        primary: crate::tts_preferences::TtsSelection {
            model_id: Some("custom-medium".into()),
            ..Default::default()
        },
        secondary: None,
        ..Default::default()
    });
    let key = if let Some(preferences) = &preferences {
        let session =
            crate::tts_session::SessionSelection::from_legacy(&preferences.primary).unwrap();
        let descriptor = crate::tts_session::builtin_descriptors()
            .into_iter()
            .find(|d| d.provider == session.provider && d.runtime == session.runtime)
            .unwrap();
        let identities = vec![
            serde_json::to_string(&(
                crate::tts_session::CONTRACT_VERSION,
                crate::tts_session::TEXT_PLANNER_PROFILE,
                &session,
                &descriptor,
                crate::tts_session::AudioFormat::Mp3,
            ))
            .unwrap(),
            cache::sha256_file(&model).unwrap(),
            cache::sha256_file(&voice_config).unwrap(),
        ];
        let material = crate::tts_session::request_cache_material(
            &base_key,
            Some("en"),
            preferences,
            &identities,
        )
        .unwrap();
        cache::sha256_bytes(material.as_bytes())
    } else {
        base_key
    };
    let job = "low-current";
    let predecessor = if recover { "low-predecessor" } else { job };
    let filename = format!("0001-{}.mp3", sanitize(&chapter.name));
    let retained = config.paths.output_dir.join(predecessor).join(&filename);
    ensure_chapter_audio(&retained, &key, |pending| {
        fs::write(
            pending,
            crate::pcm::encode_wav_mp3(&test_system_wav()).unwrap(),
        )?;
        Ok(())
    })
    .unwrap();
    if let Some(preferences) = &preferences {
        let receipt_path = chapter_audio_receipt_path(&retained);
        let mut receipt: ChapterAudioReceipt = cache::read_json(&receipt_path).unwrap();
        receipt.provider = Some("piper".into());
        receipt.used_selections = vec![preferences.primary.clone()];
        cache::atomic_write_json(&receipt_path, &receipt).unwrap();
        assert!(chapter_audio_is_reusable(&retained, &key, true));
    }
    let original_audio = fs::read(&retained).unwrap();
    let original_receipt = fs::read(chapter_audio_receipt_path(&retained)).unwrap();
    let control = ConversionControl::new();
    if recover {
        control.set_recovery_job(predecessor).unwrap();
    }
    let output = config.paths.output_dir.join(job).join(&filename);
    let worker = ConversionWorker::new(config).unwrap().with_control(control);
    let result = worker.run(ConversionRequest {
        tts_preferences: preferences,
        models_root: None,
        input,
        job_id: job.into(),
        engine: Some("piper".into()),
        voice: None,
        language: Some("en".into()),
        piper_model: Some(model.clone()),
        piper_config: Some(voice_config),
        chapter_indices: Some(vec!["0".into()]),
        no_parallel: true,
    });
    assert!(
        result.is_err(),
        "Legacy low audio was accepted through cache/recovery"
    );
    assert!(result.unwrap_err().to_string().contains("low quality"));
    assert_eq!(fs::read(retained).unwrap(), original_audio);
    assert_eq!(
        fs::read(chapter_audio_receipt_path(&if recover {
            worker
                .config
                .paths
                .output_dir
                .join(predecessor)
                .join(&filename)
        } else {
            output.clone()
        }))
        .unwrap(),
        original_receipt
    );
    assert_eq!(fs::read(model).unwrap(), b"preserved model");
    if recover {
        assert!(
            !output.exists(),
            "Rejected low audio must never be imported"
        );
    }
}

#[test]
fn explicit_low_piper_binds_the_installed_namespace_and_rejects_wrong_artifacts() {
    use crate::{
        model_catalog::{model_by_id, model_revision},
        tts_preferences::{TtsPreferences, TtsSelection},
        tts_session::SessionSelection,
    };

    let root = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        root.path().to_path_buf(),
    ));
    let worker = ConversionWorker::new(config).unwrap();
    let id = "en_US-lessac-low";
    let models_root = root.path().join("models");
    let namespace = models_root.join(id);
    fs::create_dir_all(&namespace).unwrap();
    let model = namespace.join("model.onnx");
    let voice_config = namespace.join("model.onnx.json");
    fs::write(&model, b"unverified catalog bytes").unwrap();
    fs::write(&voice_config, br#"{"audio":{"quality":"low"}}"#).unwrap();

    let mut selected = TtsSelection {
        model_id: Some(id.into()),
        ..TtsSelection::default()
    };
    let mut capture = SessionSelection::from_legacy(&selected).unwrap();
    capture.model_revision = model_revision(model_by_id(id).unwrap());
    selected.session = Some(capture);
    let preferences = TtsPreferences {
        primary: selected.clone(),
        ..Default::default()
    };
    let request = ConversionRequest {
        tts_preferences: Some(preferences.clone()),
        models_root: Some(models_root),
        input: root.path().join("unused.epub"),
        job_id: "explicit-low".into(),
        engine: Some("piper".into()),
        voice: None,
        language: Some("en-US".into()),
        piper_model: Some(root.path().join("unrelated.onnx")),
        piper_config: Some(root.path().join("unrelated.json")),
        chapter_indices: None,
        no_parallel: true,
    };
    assert_eq!(
        worker.selection_model_paths(&request, &selected),
        (model.clone(), voice_config)
    );
    let error = worker
        .typed_cache_request_key(&request, &preferences, Some("en-US"), "source")
        .unwrap_err();
    assert!(error
        .to_string()
        .contains("does not match its catalog artifacts"));
    assert_eq!(fs::read(model).unwrap(), b"unverified catalog bytes");
}
