    #[test]
    fn embedded_apple_conversion_uses_bounded_two_chapter_parallelism() {
        assert_eq!(
            embedded_chapter_parallelism_cap(),
            if cfg!(target_os = "macos") || cfg!(target_os = "ios") {
                2
            } else {
                1
            }
        );
    }

    #[test]
    fn progress_log_line_contains_wall_and_relative_timing() {
        let started = std::time::Instant::now();
        let previous = std::sync::Mutex::new(started);
        let event = converter_core::worker::ProgressEvent {
            model_id: None,
            voice: None,
            fallback_used: false,
            job_id: "timing-test".into(),
            state: "running".into(),
            chapter_index: Some(3),
            chapters_total: 10,
            chapters_completed: 2,
            percent: 20.0,
            engine: Some("edge".into()),
            message: "converting chapter 4".into(),
        };
        let line = progress_log_line(&event, started, &previous);
        assert!(line.contains("unix_ms="));
        assert!(line.contains("elapsed_ms="));
        assert!(line.contains("since_event_ms="));
        assert!(line.contains("converting chapter 4"));
    }

    #[test]
    fn null_handles_report_errors_and_free_safely() {
        unsafe {
            converter_session_free(ptr::null_mut());
            converter_string_free(ptr::null_mut());
            assert!(converter_session_metadata_json(ptr::null()).is_null());
            let error = converter_last_error();
            assert_eq!(
                CStr::from_ptr(error).to_str().unwrap(),
                "invalid null session handle"
            );
            converter_string_free(error);
        }
    }

    #[test]
    fn invalid_path_reports_error() {
        let path = CString::new("/definitely/missing/book.epub").unwrap();
        unsafe {
            assert!(converter_session_open(path.as_ptr()).is_null());
            let error = converter_last_error();
            assert!(CStr::from_ptr(error)
                .to_str()
                .unwrap()
                .contains("failed to read input"));
            converter_string_free(error);
        }
    }

    #[test]
    fn shared_model_catalog_and_default_engine_are_exposed() {
        unsafe {
            let catalog = converter_tts_models_json();
            assert!(!catalog.is_null());
            let value = CStr::from_ptr(catalog).to_str().unwrap();
            assert!(value.contains("kokoro-82m"));
            converter_string_free(catalog);

            let language = CString::new("pt-BR").unwrap();
            let platform = CString::new("android").unwrap();
            let engine = converter_tts_default_engine(language.as_ptr(), platform.as_ptr(), 28);
            assert_eq!(CStr::from_ptr(engine).to_str().unwrap(), "none");
            converter_string_free(engine);
        }
    }

    #[test]
    fn ready_model_selection_requires_runtime_verified_ids() {
        let language = CString::new("en-US").unwrap();
        let platform = CString::new("macos").unwrap();
        let installed = CString::new(r#"["kokoro-82m"]"#).unwrap();
        let not_ready = CString::new("[]").unwrap();
        let ready = CString::new(r#"["kokoro-82m"]"#).unwrap();
        unsafe {
            let engine = converter_tts_installed_ready_engine(
                language.as_ptr(),
                platform.as_ptr(),
                0,
                installed.as_ptr(),
                not_ready.as_ptr(),
            );
            assert_eq!(CStr::from_ptr(engine).to_str().unwrap(), "none");
            converter_string_free(engine);

            let engine = converter_tts_installed_ready_engine(
                language.as_ptr(),
                platform.as_ptr(),
                0,
                installed.as_ptr(),
                ready.as_ptr(),
            );
            assert_eq!(CStr::from_ptr(engine).to_str().unwrap(), "kokoro");
            converter_string_free(engine);
        }
    }

    #[test]
    fn manifest_rejects_invalid_json_before_network_access() {
        let model = CString::new("kokoro-82m").unwrap();
        let artifacts = CString::new("not-json").unwrap();
        let root = tempfile::tempdir().unwrap();
        let root = CString::new(root.path().to_str().unwrap()).unwrap();
        unsafe {
            assert!(converter_tts_model_install_manifest(
                model.as_ptr(),
                artifacts.as_ptr(),
                root.as_ptr()
            )
            .is_null());
            let error = converter_last_error();
            assert!(CStr::from_ptr(error)
                .to_str()
                .unwrap()
                .contains("invalid model artifacts JSON"));
            converter_string_free(error);
        }
    }

    #[test]
    fn catalog_manifest_rejects_unknown_model_before_network_access() {
        let model = CString::new("missing").unwrap();
        let tempdir = tempfile::tempdir().unwrap();
        let root = CString::new(tempdir.path().to_str().unwrap()).unwrap();
        unsafe {
            assert!(
                converter_tts_model_install_catalog_manifest(model.as_ptr(), root.as_ptr())
                    .is_null()
            );
            let error = converter_last_error();
            assert!(CStr::from_ptr(error)
                .to_str()
                .unwrap()
                .contains("unknown TTS model"));
            converter_string_free(error);
        }
    }

    #[test]
    fn valid_session_returns_metadata_json() {
        let fixture = fixture();
        let path = CString::new(fixture.path().to_str().unwrap()).unwrap();
        unsafe {
            let handle = converter_session_open(path.as_ptr());
            assert!(!handle.is_null());
            let metadata = converter_session_metadata_json(handle);
            let json = CStr::from_ptr(metadata).to_str().unwrap();
            assert!(json.contains("Test Book"));
            assert!(json.contains("chapters"));
            converter_string_free(metadata);
            converter_session_free(handle);
        }
    }
