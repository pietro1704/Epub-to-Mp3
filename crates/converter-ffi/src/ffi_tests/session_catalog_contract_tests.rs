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
        render_progress: None,
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
fn progress_log_line_names_the_active_voice() {
    let started = std::time::Instant::now();
    let previous = std::sync::Mutex::new(started);
    let event = converter_core::worker::ProgressEvent {
        render_progress: None,
        model_id: Some("pt_BR-faber-medium".into()),
        voice: Some("Luciana".into()),
        fallback_used: false,
        job_id: "voice-test".into(),
        state: "running".into(),
        chapter_index: Some(0),
        chapters_total: 1,
        chapters_completed: 0,
        percent: 1.0,
        engine: Some("piper".into()),
        message: "converting chapter 1".into(),
    };
    let line = progress_log_line(&event, started, &previous);
    assert!(line.contains("model_id=\"pt_BR-faber-medium\""), "{line}");
    assert!(line.contains("voice=\"Luciana\""), "{line}");
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
        let catalog = converter_tts_catalog_json_v3(
            c"pt-BR".as_ptr(),
            c"macos".as_ptr(),
            0,
            c"x86_64".as_ptr(),
            c"".as_ptr(),
            c"".as_ptr(),
        );
        assert!(!catalog.is_null());
        let value = CStr::from_ptr(catalog).to_str().unwrap();
        assert!(value.contains("pt_BR-faber-medium"));
        assert!(!value.contains("kokoro"));
        converter_string_free(catalog);

        let language = CString::new("pt-BR").unwrap();
        let platform = CString::new("android").unwrap();
        let engine = converter_tts_default_engine(language.as_ptr(), platform.as_ptr(), 28);
        assert_eq!(CStr::from_ptr(engine).to_str().unwrap(), "none");
        converter_string_free(engine);
    }
}

#[test]
fn versioned_session_catalog_and_selection_reject_unknown_runtime_without_online_routing() {
    unsafe {
        let catalog = converter_tts_catalog_json_v3(
            c"pt-BR".as_ptr(),
            c"macos".as_ptr(),
            0,
            c"x86_64".as_ptr(),
            c"".as_ptr(),
            c"".as_ptr(),
        );
        let value: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(catalog).to_str().unwrap()).unwrap();
        converter_string_free(catalog);
        assert_eq!(value["schema_version"], 3);
        assert_eq!(value["default_selection"]["model_id"], "pt_BR-faber-medium");
        let primary = converter_core::tts_preferences::TtsSelection::default();
        let session = converter_core::tts_session::SessionSelection::from_legacy(&primary).unwrap();
        let mut options = serde_json::json!({"contract_version":2,"language":"pt-BR","tts_preferences":{
                "primary":{"engine":"piper","model_id":"pt_BR-faber-medium","session":session},
                "secondary":null,"allow_online_fallback":false}});
        let encode = |value: &serde_json::Value| CString::new(value.to_string()).unwrap();
        assert!(converter_conversion_options_validate_json_v2(
            encode(&options).as_ptr()
        ));
        options["tts_preferences"]["primary"]["session"]["runtime"] = "unknown".into();
        assert!(!converter_conversion_options_validate_json_v2(
            encode(&options).as_ptr()
        ));
        let error = converter_last_error();
        assert!(CStr::from_ptr(error)
            .to_str()
            .unwrap()
            .contains("unavailable"));
        converter_string_free(error);
        options["contract_version"] = 3.into();
        assert!(!converter_conversion_options_validate_json_v2(
            encode(&options).as_ptr()
        ));
    }
}

#[test]
fn versioned_model_catalog_v3_separates_descriptors_from_offline_inspection() {
    let root = tempfile::tempdir().unwrap();
    let marker = root.path().join("preserved.txt");
    std::fs::write(&marker, b"preserve").unwrap();
    let language = CString::new("pt-BR").unwrap();
    let platform = CString::new("macos").unwrap();
    let architecture = CString::new("x86_64").unwrap();
    let os_version = CString::new("15.5").unwrap();
    let model_root = CString::new(root.path().to_str().unwrap()).unwrap();

    unsafe {
        let catalog = converter_tts_catalog_json_v3(
            language.as_ptr(),
            platform.as_ptr(),
            0,
            architecture.as_ptr(),
            os_version.as_ptr(),
            model_root.as_ptr(),
        );
        assert!(!catalog.is_null());
        let value: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(catalog).to_str().unwrap()).unwrap();
        converter_string_free(catalog);
        assert_eq!(value["schema_version"], 3);
        let entries = value["entries"].as_array().unwrap();
        let faber = entries
            .iter()
            .find(|entry| entry["identity"]["model_id"] == "pt_BR-faber-medium")
            .unwrap();
        assert_eq!(faber["presentation"]["model_name"], "Faber");
        assert_eq!(faber["installation"]["state"], "missing");
        assert_eq!(faber["readiness"]["state"], "not_inspected");
        let placeholder = entries
            .iter()
            .find(|entry| entry["identity"]["model_id"] == "piper-default")
            .unwrap();
        assert_eq!(placeholder["distribution"]["installable"], false);
        assert_eq!(placeholder["selection"]["selectable"], false);

        let descriptors = converter_tts_catalog_json_v3(
            c"pt-BR".as_ptr(),
            c"macos".as_ptr(),
            0,
            c"x86_64".as_ptr(),
            c"".as_ptr(),
            c"".as_ptr(),
        );
        assert!(!descriptors.is_null());
        let descriptor_value: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(descriptors).to_str().unwrap()).unwrap();
        converter_string_free(descriptors);
        let entries = descriptor_value["entries"].as_array().unwrap();
        for model in converter_core::model_catalog::MODELS {
            let entry = entries
                .iter()
                .find(|entry| entry["identity"]["model_id"] == model.id)
                .unwrap();
            assert_eq!(
                entry["compatibility"]["platforms"],
                serde_json::json!(model.platforms)
            );
            assert_eq!(
                entry["compatibility"]["minimum_android_api"],
                serde_json::json!(model.minimum_android_api)
            );
            assert_eq!(
                entry["compatibility"]["runtime_available"],
                model.runtime_available
            );
            assert_eq!(
                entry["distribution"]["artifacts"],
                serde_json::json!(model.artifacts)
            );
            assert_eq!(entry["installation"]["state"], "not_inspected");
            assert_eq!(entry["readiness"]["state"], "not_inspected");
        }
    }
    assert_eq!(std::fs::read(marker).unwrap(), b"preserve");
}

#[test]
fn versioned_model_catalog_v3_rejects_invalid_target_before_inspection() {
    let value = |text: &str| CString::new(text).unwrap();
    let root = tempfile::tempdir().unwrap();
    let model_root = CString::new(root.path().to_str().unwrap()).unwrap();

    unsafe {
        let catalog = converter_tts_catalog_json_v3(
            value("pt-BR").as_ptr(),
            value("unsupported").as_ptr(),
            0,
            value("x86_64").as_ptr(),
            value("15.5").as_ptr(),
            model_root.as_ptr(),
        );
        assert!(catalog.is_null());
        let error = converter_last_error();
        assert!(CStr::from_ptr(error)
            .to_str()
            .unwrap()
            .contains("unsupported platform"));
        converter_string_free(error);
    }
}

#[test]
fn explicit_model_probe_does_not_load_or_create_missing_models() {
    let root = tempfile::tempdir().unwrap();
    let marker = root.path().join("keep.marker");
    std::fs::write(&marker, b"preserve").unwrap();
    let text = |value: &str| CString::new(value).unwrap();
    unsafe {
        let result = converter_tts_catalog_probe_json_v3(
            text("pt-BR").as_ptr(),
            text("macos").as_ptr(),
            0,
            text("x86_64").as_ptr(),
            text("12.0").as_ptr(),
            text(root.path().to_str().unwrap()).as_ptr(),
            text("/no-phonemizer-needed").as_ptr(),
        );
        assert!(!result.is_null());
        let snapshot: serde_json::Value =
            serde_json::from_slice(CStr::from_ptr(result).to_bytes()).unwrap();
        converter_string_free(result);
        for entry in snapshot["entries"].as_array().unwrap() {
            assert_ne!(entry["readiness"]["state"], "ready");
            assert_eq!(entry["selection"]["selectable"], false);
        }
        assert_eq!(
            snapshot["default_selection"]["model_id"],
            "pt_BR-faber-medium"
        );
    }
    assert_eq!(std::fs::read(marker).unwrap(), b"preserve");
    assert_eq!(root.path().read_dir().unwrap().count(), 1);
}

#[test]
fn ready_model_selection_requires_runtime_verified_ids() {
    let language = CString::new("pt-BR").unwrap();
    let platform = CString::new("macos").unwrap();
    let installed = CString::new(r#"["pt_BR-faber-medium"]"#).unwrap();
    let not_ready = CString::new("[]").unwrap();
    let ready = CString::new(r#"["pt_BR-faber-medium"]"#).unwrap();
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
        assert_eq!(CStr::from_ptr(engine).to_str().unwrap(), "piper");
        converter_string_free(engine);
    }
}

#[test]
fn manifest_rejects_invalid_json_before_network_access() {
    let model = CString::new("pt_BR-faber-medium").unwrap();
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
            converter_tts_model_install_catalog_manifest(model.as_ptr(), root.as_ptr()).is_null()
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

#[test]
fn versioned_conversion_rejects_missing_capture_before_creating_a_job() {
    let book = fixture();
    let root = tempfile::tempdir().unwrap();
    let input = CString::new(book.path().to_str().unwrap()).unwrap();
    let output = CString::new(root.path().join("invalid-capture").to_str().unwrap()).unwrap();
    let job = CString::new("invalid-capture").unwrap();
    let options = CString::new(r#"{"contract_version":2,"language":"pt-BR"}"#).unwrap();
    unsafe {
        let session = converter_session_open(input.as_ptr());
        assert!(!session.is_null());
        let control = converter_job_control_create();
        let result = converter_session_convert_streaming_job_options_json_v1(
            session,
            output.as_ptr(),
            job.as_ptr(),
            options.as_ptr(),
            0,
            -1,
            None,
            None,
            None,
            ptr::null_mut(),
            control,
        );
        assert!(result.is_null());
        let error = converter_last_error();
        assert_eq!(
            CStr::from_ptr(error).to_str().unwrap(),
            "Version 2 requires captured TTS preferences"
        );
        converter_string_free(error);
        converter_job_control_free(control);
        converter_session_free(session);
    }
    assert!(!root.path().join(".jobs/invalid-capture.json").exists());
}

#[test]
fn manual_catalog_and_targeted_probe_expose_low_piper_only_by_opt_in() {
    let root = tempfile::tempdir().unwrap();
    let model_root = CString::new(root.path().to_str().unwrap()).unwrap();
    let read = |result: *mut c_char| unsafe {
        assert!(!result.is_null());
        let value: serde_json::Value =
            serde_json::from_slice(CStr::from_ptr(result).to_bytes()).unwrap();
        converter_string_free(result);
        value
    };
    unsafe {
        let manual = read(converter_tts_catalog_manual_json_v3(
            c"pt-BR".as_ptr(),
            c"macos".as_ptr(),
            0,
            c"x86_64".as_ptr(),
            c"".as_ptr(),
            model_root.as_ptr(),
        ));
        let entry = manual["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["identity"]["model_id"] == "pt_BR-edresson-low")
            .unwrap();
        assert_eq!(entry["presentation"]["quality"], "low");
        assert_eq!(entry["distribution"]["installable"], true);
        assert_eq!(entry["installation"]["state"], "missing");
        assert_eq!(entry["selection"]["selectable"], false);
        assert_eq!(
            manual["default_selection"]["model_id"],
            "pt_BR-faber-medium"
        );

        let targeted = read(converter_tts_catalog_probe_model_json_v3(
            c"pt-BR".as_ptr(),
            c"macos".as_ptr(),
            0,
            c"x86_64".as_ptr(),
            c"".as_ptr(),
            model_root.as_ptr(),
            c"/no-phonemizer-needed".as_ptr(),
            c"pt_BR-edresson-low".as_ptr(),
        ));
        assert_eq!(targeted["entries"], serde_json::json!([entry]));

        let automatic = read(converter_tts_catalog_json_v3(
            c"pt-BR".as_ptr(),
            c"macos".as_ptr(),
            0,
            c"x86_64".as_ptr(),
            c"".as_ptr(),
            model_root.as_ptr(),
        ));
        assert!(automatic["entries"]
            .as_array()
            .unwrap()
            .iter()
            .all(|entry| entry["presentation"]["quality"] != "low"));
    }
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
}
