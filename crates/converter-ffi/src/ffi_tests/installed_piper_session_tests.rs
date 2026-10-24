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
