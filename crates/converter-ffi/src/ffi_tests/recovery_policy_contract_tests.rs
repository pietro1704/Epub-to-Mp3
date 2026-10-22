    #[test]
    fn controlled_ffi_recovery_preserves_explicit_zero_and_nonzero_policy_without_synthesis() {
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
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
            let convert = |job: &str, predecessor: Option<&str>, failures: usize| {
                let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
                let job = CString::new(job).unwrap();
                let options = CString::new(
                    serde_json::json!({
                        "language": "pt-BR",
                        "tts_preferences": {
                            "primary": {"engine":"system", "model_id":null, "voice":null},
                            "secondary": null, "allow_online_fallback": false
                        },
                        "tts_policy_state": {"consecutive_failures": failures}
                    })
                    .to_string(),
                )
                .unwrap();
                let control = converter_job_control_create();
                assert!(!control.is_null());
                if let Some(predecessor) = predecessor {
                    let source = CString::new(predecessor).unwrap();
                    assert!(converter_job_control_set_recovery_job(
                        control,
                        source.as_ptr()
                    ));
                }
                let response = converter_session_convert_controlled_job_options_json_v1(
                    session,
                    output.as_ptr(),
                    job.as_ptr(),
                    options.as_ptr(),
                    0,
                    0,
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
                    panic!("actual policy recovery failed: {message}");
                }
                let result: serde_json::Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                converter_string_free(response);
                result
            };
            let original = convert("policy-predecessor", None, 2);
            let original_calls = calls.load(std::sync::atomic::Ordering::Acquire);
            assert!(original_calls > 0);
            assert_eq!(
                original["manifest"]["ttsPolicyState"]["consecutive_failures"],
                0
            );
            let original_audio = Path::new(original["audioPath"].as_str().unwrap());
            let audio_bytes = std::fs::read(original_audio).unwrap();
            let receipt_path = original_audio.with_extension("mp3.complete.json");
            let receipt_bytes = std::fs::read(&receipt_path).unwrap();
            let state_path = root.path().join(".jobs/policy-predecessor.json");
            let predecessor_state = std::fs::read(&state_path).unwrap();
            for failures in [0, 2] {
                let job = format!("policy-recovered-{failures}");
                let recovered = convert(&job, Some("policy-predecessor"), failures);
                assert_eq!(
                    calls.load(std::sync::atomic::Ordering::Acquire),
                    original_calls
                );
                assert_eq!(
                    recovered["manifest"]["ttsPolicyState"]["consecutive_failures"],
                    failures
                );
                assert_eq!(
                    recovered["manifest"]["usedSelections"],
                    original["manifest"]["usedSelections"]
                );
                assert_eq!(
                    recovered["manifest"]["fallbackUsed"],
                    original["manifest"]["fallbackUsed"]
                );
                let persisted: serde_json::Value = serde_json::from_slice(
                    &std::fs::read(root.path().join(&job).join("manifest.json")).unwrap(),
                )
                .unwrap();
                assert_eq!(
                    persisted["ttsPolicyState"]["consecutive_failures"],
                    failures
                );
                let recovered_audio = Path::new(recovered["audioPath"].as_str().unwrap());
                assert_eq!(std::fs::read(recovered_audio).unwrap(), audio_bytes);
                assert_eq!(
                    std::fs::read(recovered_audio.with_extension("mp3.complete.json")).unwrap(),
                    receipt_bytes
                );
            }
            assert_eq!(std::fs::read(original_audio).unwrap(), audio_bytes);
            assert_eq!(std::fs::read(receipt_path).unwrap(), receipt_bytes);
            assert_eq!(std::fs::read(state_path).unwrap(), predecessor_state);
            converter_session_free(session);
        }
    }

    #[test]
    fn controlled_ffi_recovery_reuses_validated_predecessor_without_synthesis() {
        let book = fixture();
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
            let convert = |job: &str, predecessor: Option<&str>| {
                let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
                let job = CString::new(job).unwrap();
                let control = converter_job_control_create();
                assert!(!control.is_null());
                if let Some(predecessor) = predecessor {
                    let source = CString::new(predecessor).unwrap();
                    assert!(converter_job_control_set_recovery_job(
                        control,
                        source.as_ptr()
                    ));
                }
                let response = converter_session_convert_controlled_job_options_json_v1(
                    session,
                    output.as_ptr(),
                    job.as_ptr(),
                    options.as_ptr(),
                    0,
                    0,
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
                    panic!("actual recovery conversion failed: {message}");
                }
                let manifest: serde_json::Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                converter_string_free(response);
                manifest
            };
            let original = convert("recovery-predecessor", None);
            let original_calls = calls.load(std::sync::atomic::Ordering::Acquire);
            assert!(
                original_calls > 0,
                "Predecessor must synthesize through the actual FFI provider"
            );
            assert!(!original["manifest"]["usedSelections"]
                .as_array()
                .unwrap()
                .is_empty());
            let original_audio = Path::new(original["audioPath"].as_str().unwrap());
            let original_bytes = std::fs::read(original_audio).unwrap();
            converter_core::pcm::validate_mp3(&original_bytes).unwrap();
            let original_receipt_path = original_audio.with_extension("mp3.complete.json");
            let original_receipt = std::fs::read(&original_receipt_path).unwrap();
            let original_manifest =
                std::fs::read(root.path().join("recovery-predecessor/manifest.json")).unwrap();
            let original_state =
                std::fs::read(root.path().join(".jobs/recovery-predecessor.json")).unwrap();

            let recovered = convert("recovery-successor", Some("recovery-predecessor"));
            converter_session_free(session);
            assert_eq!(
                calls.load(std::sync::atomic::Ordering::Acquire),
                original_calls,
                "A matching durable predecessor must avoid synthesizing its completed chapter again",
            );
            assert_eq!(recovered["manifest"]["jobId"], "recovery-successor");
            let recovered_audio = Path::new(recovered["audioPath"].as_str().unwrap());
            assert!(recovered_audio.starts_with(root.path().join("recovery-successor")));
            assert_eq!(std::fs::read(recovered_audio).unwrap(), original_bytes);
            assert_eq!(
                std::fs::read(recovered_audio.with_extension("mp3.complete.json")).unwrap(),
                original_receipt
            );
            assert_eq!(
                recovered["manifest"]["usedSelections"],
                original["manifest"]["usedSelections"]
            );
            assert_eq!(
                recovered["manifest"]["fallbackUsed"],
                original["manifest"]["fallbackUsed"]
            );
            assert_eq!(std::fs::read(original_audio).unwrap(), original_bytes);
            assert_eq!(
                std::fs::read(original_receipt_path).unwrap(),
                original_receipt
            );
            assert_eq!(
                std::fs::read(root.path().join("recovery-predecessor/manifest.json")).unwrap(),
                original_manifest
            );
            assert_eq!(
                std::fs::read(root.path().join(".jobs/recovery-predecessor.json")).unwrap(),
                original_state
            );
        }
    }
