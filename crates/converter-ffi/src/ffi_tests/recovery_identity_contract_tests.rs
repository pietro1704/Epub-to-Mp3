#[test]
fn controlled_ffi_recovery_regenerates_opaque_voice_after_selection_renumbers_its_filename() {
    let book = fixture_chapters(2);
    let root = tempfile::tempdir().unwrap();
    let input = CString::new(book.path().to_str().unwrap()).unwrap();
    let options = CString::new(r#"{"language":"pt-BR","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null},"secondary":null,"allow_online_fallback":false}}"#).unwrap();
    let calls = std::sync::atomic::AtomicUsize::new(0);
    unsafe {
        let session = converter_session_open(input.as_ptr());
        assert!(!session.is_null());
        assert!(converter_session_set_platform_tts_v1(
            session,
            Some(platform_test_speech),
            (&calls as *const std::sync::atomic::AtomicUsize)
                .cast_mut()
                .cast(),
        ));
        let convert = |job: &str, start: i32| {
            let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
            let job_id = CString::new(job).unwrap();
            let control = converter_job_control_create();
            if start == 1 {
                let source = CString::new("selection-predecessor").unwrap();
                assert!(converter_job_control_set_recovery_job(
                    control,
                    source.as_ptr()
                ));
            }
            let response = converter_session_convert_controlled_job_options_json_v1(
                session,
                output.as_ptr(),
                job_id.as_ptr(),
                options.as_ptr(),
                start,
                1,
                None,
                None,
                ptr::null_mut(),
                control,
            );
            converter_job_control_free(control);
            if response.is_null() {
                let error = converter_last_error();
                let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                converter_string_free(error);
                panic!("Selection fixture {job} failed: {message}");
            }
            let value: serde_json::Value =
                serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            converter_string_free(response);
            value
        };
        let original = convert("selection-predecessor", 0);
        let original_calls = calls.load(std::sync::atomic::Ordering::Acquire);
        assert_eq!(
            original_calls, 4,
            "Both source chapters must synthesize their heading and body"
        );
        let chapter = &original["manifest"]["chapters"][1];
        let source_audio = root
            .path()
            .join("selection-predecessor")
            .join(chapter["filename"].as_str().unwrap());
        let source_bytes = std::fs::read(&source_audio).unwrap();
        let source_receipt =
            std::fs::read(source_audio.with_extension("mp3.complete.json")).unwrap();

        let recovered = convert("selection-successor", 1);
        converter_session_free(session);

        assert_eq!(
            calls.load(std::sync::atomic::Ordering::Acquire),
            original_calls + 2,
            "Source identity alone must not admit an unresolved system voice"
        );
        let destination = Path::new(recovered["audioPath"].as_str().unwrap());
        assert_ne!(destination.file_name(), source_audio.file_name());
        assert_eq!(
            recovered["manifest"]["chapters"].as_array().unwrap().len(),
            1
        );
        assert_eq!(recovered["manifest"]["chapters"][0]["sourceIndex"], 1);
        assert_eq!(std::fs::read(destination).unwrap(), source_bytes);
        assert_ne!(
            std::fs::read(destination.with_extension("mp3.complete.json")).unwrap(),
            source_receipt
        );
        assert_eq!(
            std::fs::read(source_audio.with_extension("mp3.complete.json")).unwrap(),
            source_receipt
        );
    }
}

#[test]
fn controlled_ffi_recovery_does_not_reuse_a_different_source() {
    let book = fixture();
    let changed_book = fixture_chapters_with_text(1, "This is a different source book.");
    let root = tempfile::tempdir().unwrap();
    let calls = std::sync::atomic::AtomicUsize::new(0);
    unsafe {
        let mut predecessor_receipt = Vec::new();
        let mut predecessor_state = Vec::new();
        let mut predecessor_audio = std::path::PathBuf::new();
        let mut predecessor_calls = 0;
        for (job, source) in [
            ("source-predecessor", book.path()),
            ("source-successor", changed_book.path()),
        ] {
            let input = CString::new(source.to_str().unwrap()).unwrap();
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast(),
            ));
            let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
            let job_id = CString::new(job).unwrap();
            let options = CString::new(
                serde_json::json!({
                    "language": "pt-BR",
                    "tts_preferences": {
                        "primary": {"engine": "system", "model_id": null, "voice": null},
                        "secondary": null, "allow_online_fallback": false
                    }
                })
                .to_string(),
            )
            .unwrap();
            let control = converter_job_control_create();
            if job == "source-successor" {
                let source = CString::new("source-predecessor").unwrap();
                assert!(converter_job_control_set_recovery_job(
                    control,
                    source.as_ptr()
                ));
            }
            let response = converter_session_convert_controlled_job_options_json_v1(
                session,
                output.as_ptr(),
                job_id.as_ptr(),
                options.as_ptr(),
                0,
                0,
                None,
                None,
                ptr::null_mut(),
                control,
            );
            converter_job_control_free(control);
            converter_session_free(session);
            if response.is_null() {
                let error = converter_last_error();
                let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                converter_string_free(error);
                panic!("Local fixture conversion {job} failed: {message}");
            }
            let value: serde_json::Value =
                serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            converter_string_free(response);
            let audio = Path::new(value["audioPath"].as_str().unwrap());
            let receipt = std::fs::read(audio.with_extension("mp3.complete.json")).unwrap();
            let metadata: serde_json::Value = serde_json::from_slice(&receipt).unwrap();
            assert_eq!(metadata["used_selections"][0]["engine"], "system");
            if job == "source-predecessor" {
                predecessor_calls = calls.load(std::sync::atomic::Ordering::Acquire);
                assert!(predecessor_calls > 0);
                predecessor_audio = audio.to_path_buf();
                predecessor_receipt = receipt;
                predecessor_state =
                    std::fs::read(root.path().join(".jobs/source-predecessor.json")).unwrap();
            } else {
                assert!(
                    calls.load(std::sync::atomic::Ordering::Acquire) > predecessor_calls,
                    "A different source must synthesize instead of adopting predecessor audio"
                );
                let original: serde_json::Value =
                    serde_json::from_slice(&predecessor_receipt).unwrap();
                assert_ne!(metadata["request_key"], original["request_key"]);
            }
        }
        assert_eq!(
            std::fs::read(predecessor_audio.with_extension("mp3.complete.json")).unwrap(),
            predecessor_receipt
        );
        assert_eq!(
            std::fs::read(root.path().join(".jobs/source-predecessor.json")).unwrap(),
            predecessor_state
        );
    }
}
