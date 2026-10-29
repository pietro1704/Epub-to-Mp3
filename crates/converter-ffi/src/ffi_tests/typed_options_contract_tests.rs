    #[test]
    fn opaque_tts_policy_state_rejects_invalid_or_exhausted_counters() {
        for failures in [0, 1, 2] {
            let options =
                format!(r#"{{"tts_policy_state":{{"consecutive_failures":{failures}}}}}"#);
            assert!(serde_json::from_str::<EmbeddedConversionOptionsV1>(&options).is_ok());
        }
        for state in [
            r#"{"consecutive_failures":3}"#,
            r#"{"consecutive_failures":-1}"#,
            r#"{"other":0}"#,
            r#""invalid""#,
        ] {
            let options = format!(r#"{{"tts_policy_state":{state}}}"#);
            assert!(serde_json::from_str::<EmbeddedConversionOptionsV1>(&options).is_err());
        }
    }
    #[test]
    fn incompatible_book_language_preflight_only_allows_versioned_native_continuation() {
        let root = tempfile::tempdir().unwrap();
        let mut preferences = converter_core::tts_preferences::TtsPreferences::app_default(true);
        let mut options = serde_json::json!({
            "language": "en",
            "models_root": root.path(),
            "tts_preferences": preferences,
        });
        let validate = |options: &serde_json::Value| {
            let json = CString::new(options.to_string()).unwrap();
            unsafe { converter_conversion_options_validate_json_v1(json.as_ptr()) }
        };
        assert!(validate(&options));
        assert!(root.path().read_dir().unwrap().next().is_none());
        preferences.policy_version = None;
        options["tts_preferences"] = serde_json::to_value(&preferences).unwrap();
        assert!(!validate(&options));
        preferences.policy_version = Some(2);
        preferences.secondary = None;
        options["tts_preferences"] = serde_json::to_value(&preferences).unwrap();
        assert!(validate(&options));
        preferences = preferences.effective_selection(None, false);
        assert!(!preferences.continues_native());
        options["tts_preferences"] = serde_json::to_value(&preferences).unwrap();
        assert!(!validate(&options));
    }
    #[test]
    fn missing_model_preflight_only_allows_versioned_native_continuation() {
        let root = tempfile::tempdir().unwrap();
        let mut options = EmbeddedConversionOptionsV1 {
            models_root: Some(root.path().to_string_lossy().into_owned()),
            model_id: Some(converter_core::tts_preferences::FABER_MODEL_ID.into()),
            tts_preferences: Some(
                converter_core::tts_preferences::TtsPreferences::app_default(true),
            ),
            ..Default::default()
        };
        let (model, config) = resolve_piper_model_paths(&options).unwrap();
        assert!(!model.exists());
        assert!(!config.exists());
        options.models_root = None;
        assert!(resolve_piper_model_paths(&options).is_ok());
        options.tts_preferences.as_mut().unwrap().policy_version = None;
        assert!(resolve_piper_model_paths(&options).is_err());
        options.tts_preferences.as_mut().unwrap().policy_version = Some(2);
        options.model_path = Some("../escape.onnx".into());
        assert!(resolve_piper_model_paths(&options).is_err());
    }

    #[test]
    fn versioned_missing_piper_converts_through_registered_native_callback() {
        let book = fixture_chapters_with_text(1, &"Uma frase com ação e coração. ".repeat(100));
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(root.path().join("fallback-job").to_str().unwrap()).unwrap();
        let job = CString::new("fallback-job").unwrap();
        let options = CString::new(serde_json::json!({
            "language":"pt-BR",
            "tts_preferences": converter_core::tts_preferences::TtsPreferences::app_default(true)
        }).to_string()).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            assert!(converter_conversion_options_validate_json_v1(
                options.as_ptr()
            ));
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast()
            ));
            let control = converter_job_control_create();
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
            if response.is_null() {
                let error = converter_last_error();
                let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                converter_string_free(error);
                panic!("versioned native fallback failed: {message}");
            }
            let value: serde_json::Value =
                serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            converter_string_free(response);
            assert!(calls.load(std::sync::atomic::Ordering::Acquire) > 3);
            assert_eq!(value["manifest"]["fallbackUsed"], true);
            assert_eq!(value["manifest"]["usedSelections"][0]["engine"], "system");
            converter_session_free(session);
            converter_job_control_free(control);
        }
    }

    #[test]
    fn configured_only_missing_piper_never_invokes_registered_system_callback() {
        let book = fixture_chapters_with_text(1, "Uma frase para testar a voz selecionada.");
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let directory = root.path().join("configured-only-job");
        let output = CString::new(directory.to_str().unwrap()).unwrap();
        let job = CString::new("configured-only-job").unwrap();
        let mut preferences = converter_core::tts_preferences::TtsPreferences::app_default(true);
        preferences.policy_version = Some(3);
        preferences.secondary = None;
        let options = CString::new(serde_json::json!({
            "language": "pt-BR",
            "models_root": root.path().join("missing-models"),
            "tts_preferences": preferences
        }).to_string()).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            assert!(converter_conversion_options_validate_json_v1(options.as_ptr()));
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session, Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize).cast_mut().cast()
            ));
            let control = converter_job_control_create();
            let response = converter_session_convert_controlled_job_options_json_v1(
                session, output.as_ptr(), job.as_ptr(), options.as_ptr(),
                0, 0, None, None, ptr::null_mut(), control,
            );
            assert!(response.is_null(), "Missing selected Piper must fail without system audio");
            let error = converter_last_error();
            assert!(!error.is_null());
            let message = CStr::from_ptr(error).to_string_lossy().into_owned();
            converter_string_free(error);
            assert!(message.contains("model file operation failed"), "{message}");
            assert_eq!(calls.load(std::sync::atomic::Ordering::Acquire), 0);
            assert!(!directory.join("manifest.json").exists());
            converter_session_free(session);
            converter_job_control_free(control);
        }
    }

    #[test]
    fn controlled_typed_options_honor_voice_and_cancel_after_first_real_chapter() {
        let book = fixture_chapters(3);
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("typed-controlled-job");
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(directory.to_str().unwrap()).unwrap();
        let job = CString::new("typed-controlled-job").unwrap();
        // Conflicting legacy engine proves that immutable typed options win.
        let options = CString::new(r#"{"engine":"edge","language":"pt-BR","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null},"secondary":null,"allow_online_fallback":false}}"#).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast()
            ));
            let control = converter_job_control_create();
            assert!(converter_job_control_prioritize(control, 2));
            let mut fixture = ControlCallbackFixture {
                handle: control,
                chapters: Vec::new(),
                cancel_on_first: true,
                freed: false,
                recovery_rejected: false,
            };
            let response = converter_session_convert_controlled_job_options_json_v1(
                session,
                output.as_ptr(),
                job.as_ptr(),
                options.as_ptr(),
                0,
                -1,
                None,
                Some(controlled_chapter_callback),
                (&mut fixture as *mut ControlCallbackFixture).cast(),
                control,
            );
            assert!(response.is_null());
            let error = converter_last_error();
            assert!(!error.is_null());
            let message = CStr::from_ptr(error).to_string_lossy().into_owned();
            converter_string_free(error);
            assert!(message.contains("cancelled"), "{message}");
            assert_eq!(fixture.chapters, [2]);
            assert!(fixture.freed);
            assert!(calls.load(std::sync::atomic::Ordering::Acquire) > 0);
            assert!(!directory.join("manifest.json").exists());
            let completed: Vec<_> = std::fs::read_dir(&directory)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry.path().extension().is_some_and(|value| value == "mp3"))
                .collect();
            assert_eq!(
                completed.len(),
                1,
                "Cancellation must prevent synthesis of later chapters"
            );
            let jobs = converter_core::jobs::ConversionJobStore::new(root.path().join(".jobs"))
                .unwrap()
                .list()
                .unwrap();
            assert_eq!(jobs.len(), 1);
            assert_eq!(
                jobs[0].metadata["tts_preferences"]["primary"]["engine"],
                "system"
            );
            converter_session_free(session);
        }
    }
