#[cfg(feature = "piper-runtime")]
#[test]
#[ignore = "Requires an explicitly supplied existing Piper model; never downloads assets"]
fn installed_piper_session_produces_real_audio_with_captured_identity() {
    let models =
        std::env::var("TTS_TEST_INSTALLED_MODELS_ROOT").expect("Explicit existing models root");
    let data =
        std::env::var("TTS_TEST_ESPEAK_DATA_DIRECTORY").expect("Explicit existing phonemizer data");
    let book = fixture_chapters_with_text(
        1,
        "This is a short, known sentence for the installed speech runtime.",
    );
    let root = tempfile::tempdir().unwrap();
    let input = CString::new(book.path().to_str().unwrap()).unwrap();
    let output = CString::new(
        root.path()
            .join("installed-piper-session")
            .to_str()
            .unwrap(),
    )
    .unwrap();
    let job = CString::new("installed-piper-session").unwrap();
    let options = CString::new(
        json!({
            "models_root": models, "model_id": "piper", "model_path": "en_US-lessac-medium.onnx",
            "model_config_path": "en_US-lessac-medium.onnx.json", "espeak_data_directory": data,
            "language": "en-US", "tts_preferences": {
                "primary": { "engine": "piper", "model_id": "piper", "voice": null },
                "secondary": null, "allow_online_fallback": false
            }
        })
        .to_string(),
    )
    .unwrap();
    unsafe {
        let session = converter_session_open(input.as_ptr());
        assert!(!session.is_null());
        let response = converter_session_convert_job_options_json_v1(
            session,
            output.as_ptr(),
            job.as_ptr(),
            options.as_ptr(),
            0,
            0,
            None,
            None,
            ptr::null_mut(),
        );
        if response.is_null() {
            let error = converter_last_error();
            let message = CStr::from_ptr(error).to_string_lossy().into_owned();
            converter_string_free(error);
            converter_session_free(session);
            panic!("{message}");
        }
        let value: serde_json::Value =
            serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
        let bytes = std::fs::read(value["audioPath"].as_str().unwrap()).unwrap();
        assert!(converter_core::pcm::mp3_duration_seconds(&bytes).unwrap() > 1.0);
        let identities = value["manifest"]["synthesisSessions"].as_array().unwrap();
        assert_eq!(identities.len(), 1);
        assert_eq!(identities[0]["selection"]["provider"], "piper");
        assert!(identities[0]["artifacts"]["model"].as_str().unwrap().len() == 64);
        assert_ne!(value["manifest"]["fallbackUsed"], true);
        converter_string_free(response);
        converter_session_free(session);
    }
}

#[cfg(feature = "piper-runtime")]
#[test]
#[ignore = "Requires explicitly supplied installed catalogue voices; never downloads assets"]
fn installed_catalogue_voices_are_ready_and_synthesize_with_their_exact_identity() {
    let models = std::env::var("TTS_TEST_INSTALLED_MODELS_ROOT").expect("Existing installed catalogue root");
    let data = std::env::var("TTS_TEST_ESPEAK_DATA_DIRECTORY").expect("Existing phonemizer data");
    let ids: Vec<String> = serde_json::from_str(
        &std::env::var("TTS_TEST_CATALOG_MODEL_IDS").expect("Explicit JSON list of catalogue model IDs"),
    ).unwrap();
    assert!(!ids.is_empty());
    let output_root = tempfile::tempdir().unwrap();
    for id in ids {
        let model = converter_core::model_catalog::MODELS.iter().find(|model| model.id == id).unwrap();
        let evidence = model.metadata.exact_languages.first().expect("Exact locale evidence");
        let text = match evidence.tag {
            "pt-BR" => "Esta voz verifica a seleção explícita de um modelo instalado.",
            "es-ES" => "Esta voz comprueba la selección explícita de un modelo instalado.",
            _ => "This voice verifies explicit selection of an installed speech model.",
        };
        let book = fixture_chapters_with_text(1, text);
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let encode = |text: &str| CString::new(text).unwrap();
        unsafe {
            let snapshot = converter_tts_catalog_probe_json_v3(
                encode(evidence.tag).as_ptr(), encode("macos").as_ptr(), 0,
                encode("x86_64").as_ptr(), encode("12.0").as_ptr(),
                encode(&models).as_ptr(), encode(&data).as_ptr(),
            );
            assert!(!snapshot.is_null());
            let snapshot_json: serde_json::Value = serde_json::from_slice(CStr::from_ptr(snapshot).to_bytes()).unwrap();
            converter_string_free(snapshot);
            let entry = snapshot_json["entries"].as_array().unwrap().iter()
                .find(|entry| entry["identity"]["model_id"] == id).unwrap();
            assert_eq!(entry["installation"]["state"], "installed", "{id}");
            assert_eq!(entry["readiness"]["state"], "ready", "{id}");
            assert_eq!(entry["selection"]["selectable"], true, "{id}");
            let captured = json!({
                "version": 2, "provider": "piper", "runtime": "piper", "model_id": id,
                "model_revision": entry["identity"]["model_revision"], "voice": null, "options": {}
            });
            let options = CString::new(json!({
                "contract_version": 2, "models_root": models, "language": evidence.tag,
                "espeak_data_directory": data, "tts_preferences": {
                    "primary": {"engine":"piper", "model_id":id, "voice":null, "session":captured},
                    "secondary": null, "allow_online_fallback": false, "policy_version": 2
                }
            }).to_string()).unwrap();
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            let output = encode(output_root.path().join(&id).to_str().unwrap());
            let result = converter_session_convert_job_options_json_v1(
                session, output.as_ptr(), encode(&id).as_ptr(), options.as_ptr(),
                0, 0, None, None, ptr::null_mut(),
            );
            converter_session_free(session);
            assert!(!result.is_null(), "Failed synthesis for {id}");
            let converted: serde_json::Value = serde_json::from_slice(CStr::from_ptr(result).to_bytes()).unwrap();
            converter_string_free(result);
            let audio = std::fs::read(converted["audioPath"].as_str().unwrap()).unwrap();
            let duration = converter_core::pcm::mp3_duration_seconds(&audio).unwrap();
            assert!(duration > 0.0);
            let identities = converted["manifest"]["synthesisSessions"].as_array().unwrap();
            assert!(!identities.is_empty());
            assert!(identities.iter().all(|entry| entry["selection"]["model_id"] == id));
            assert_ne!(converted["manifest"]["fallbackUsed"], true);
            if let Ok(directory) = std::env::var("TTS_TEST_VOICE_EVIDENCE_DIRECTORY") {
                let directory = std::path::Path::new(&directory);
                assert!(directory.is_absolute(), "Evidence requires an explicit absolute path");
                std::fs::create_dir_all(directory).unwrap();
                let audio_path = directory.join(format!("{id}.mp3"));
                std::fs::write(&audio_path, &audio).unwrap();
                let receipt = json!({
                    "model_id": id, "language": evidence.tag,
                    "audio_path": audio_path, "duration_seconds": duration,
                    "synthesis_sessions": identities,
                });
                std::fs::write(directory.join(format!("{id}.json")), receipt.to_string()).unwrap();
                println!("MODEL_RUNTIME_ACCEPTANCE id={id} duration_seconds={duration:.3}");
            }
        }
    }
}
