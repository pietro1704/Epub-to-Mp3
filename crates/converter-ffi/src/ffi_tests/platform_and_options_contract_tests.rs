    unsafe extern "C" fn platform_test_speech(
        text: *const c_char,
        language: *const c_char,
        output: *const c_char,
        cancelled: ConverterPlatformCancelled,
        cancel_context: *const c_void,
        _error: *mut c_char,
        _error_length: u32,
        context: *mut c_void,
    ) -> bool {
        if cancelled(cancel_context) {
            return false;
        }
        assert!(!CStr::from_ptr(text).to_bytes().is_empty());
        assert_eq!(CStr::from_ptr(language).to_str().unwrap(), "pt-BR");
        let calls = &*context.cast::<std::sync::atomic::AtomicUsize>();
        calls.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let rate = 22_050u32;
        let pcm: Vec<u8> = (0..rate)
            .flat_map(|i| {
                let phase = i as f32 * 440.0 * std::f32::consts::TAU / rate as f32;
                ((phase.sin() * 8_000.0) as i16).to_le_bytes()
            })
            .collect();
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&rate.to_le_bytes());
        wav.extend_from_slice(&(rate * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        wav.extend_from_slice(&pcm);
        std::fs::write(CStr::from_ptr(output).to_str().unwrap(), wav).is_ok()
    }

    #[test]
    fn typed_preferences_are_authoritative_and_online_fallback_is_explicit() {
        let options = CString::new(r#"{"engine":"piper","tts_preferences":{"primary":{"engine":"edge","model_id":null,"voice":"pt-BR-FranciscaNeural"},"secondary":null,"allow_online_fallback":false}}"#).unwrap();
        assert!(unsafe { converter_conversion_options_validate_json_v1(options.as_ptr()) });
        let denied = CString::new(r#"{"tts_preferences":{"primary":{"engine":"piper","model_id":"pt_BR-faber-medium","voice":null},"secondary":{"engine":"edge","model_id":null,"voice":null},"allow_online_fallback":false}}"#).unwrap();
        assert!(!unsafe { converter_conversion_options_validate_json_v1(denied.as_ptr()) });
        let invalid = CString::new(r#"{"engine":"invented"}"#).unwrap();
        assert!(!unsafe { converter_conversion_options_validate_json_v1(invalid.as_ptr()) });
    }

    #[test]
    fn duplicate_job_rejection_preserves_another_invocations_record_and_outputs() {
        use converter_core::jobs::{ConversionJobStore, JobRecord, JobState};
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let manager = ConversionJobStore::new(root.path().join(".jobs")).unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let options = CString::new(r#"{"engine":"system","language":"pt-BR"}"#).unwrap();
        for state in [
            JobState::Queued,
            JobState::Running,
            JobState::Cancelled,
            JobState::Completed,
        ] {
            let id = format!("owned-{state:?}");
            let directory = root.path().join(&id);
            std::fs::create_dir_all(&directory).unwrap();
            for name in ["chapter.mp3", "manifest.json", "conversion.log"] {
                std::fs::write(directory.join(name), format!("winner-owned {name}")).unwrap();
            }
            let mut record = JobRecord::new(&id, Default::default());
            record.state = state;
            manager.create(record.clone()).unwrap();
            let record_bytes =
                std::fs::read(root.path().join(".jobs").join(format!("{id}.json"))).unwrap();
            let calls = std::sync::atomic::AtomicUsize::new(0);
            let output = CString::new(directory.to_str().unwrap()).unwrap();
            let job = CString::new(id).unwrap();
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
                assert!(response.is_null(), "a duplicate invocation must not start");
                let error = converter_last_error();
                assert!(!error.is_null());
                let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                converter_string_free(error);
                converter_session_free(session);
                assert!(message.contains("job storage error"), "{message}");
            }
            assert_eq!(calls.load(std::sync::atomic::Ordering::Relaxed), 0);
            assert_eq!(manager.load(&record.job_id).unwrap(), record);
            assert_eq!(
                std::fs::read(
                    root.path()
                        .join(".jobs")
                        .join(format!("{}.json", record.job_id))
                )
                .unwrap(),
                record_bytes
            );
            for name in ["chapter.mp3", "manifest.json", "conversion.log"] {
                assert_eq!(
                    std::fs::read(directory.join(name)).unwrap(),
                    format!("winner-owned {name}").as_bytes()
                );
            }
            assert_eq!(std::fs::read_dir(directory).unwrap().count(), 3);
        }
    }

    #[test]
    fn platform_callback_synthesizes_a_validated_job_without_network_or_piper() {
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(root.path().join("system-job").to_str().unwrap()).unwrap();
        let job = CString::new("system-job").unwrap();
        let options = CString::new(r#"{"engine":"system","language":"pt-BR"}"#).unwrap();
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
            assert_eq!(value["systemVoiceUsed"], true);
            assert_eq!(value["manifest"]["chapters"].as_array().unwrap().len(), 1);
            let path = value["audioPath"].as_str().unwrap();
            converter_core::audio::validate_audio(Path::new(path), 1).unwrap();
            assert!(calls.load(std::sync::atomic::Ordering::Relaxed) > 0);
            converter_string_free(response);
            assert!(converter_session_set_platform_tts_v1(
                session,
                None,
                ptr::null_mut()
            ));
            assert!((*session).platform_tts.is_none());
            converter_session_free(session);
        }
    }

    #[test]
    fn platform_callback_rejects_null_session_and_borrows_cancellation() {
        unsafe {
            assert!(!converter_session_set_platform_tts_v1(
                ptr::null_mut(),
                None,
                ptr::null_mut()
            ));
            let cancelled = || true;
            let context = PlatformCancellation {
                cancelled: &cancelled,
            };
            assert!(platform_cancelled(
                (&context as *const PlatformCancellation<'_>).cast()
            ));
            assert!(platform_cancelled(ptr::null()));
        }
    }

    #[test]
    fn embedded_engine_defaults_to_edge_and_requires_explicit_piper_selection() {
        assert_eq!(embedded_engine_from_value(None), "edge");
        assert_eq!(embedded_engine_from_value(Some("")), "edge");
        assert_eq!(embedded_engine_from_value(Some("invalid")), "edge");
        assert_eq!(embedded_engine_from_value(Some("piper")), "piper");
        assert_eq!(embedded_engine_from_value(Some(" Piper ")), "piper");
    }

    #[test]
    fn piper_requires_an_installed_model_and_voice_config() {
        let root = tempfile::tempdir().unwrap();
        let model_dir = root.path().join("pt_BR-edresson-low");
        std::fs::create_dir_all(&model_dir).unwrap();
        let model = model_dir.join("model.onnx");
        std::fs::write(&model, b"fixture").unwrap();
        let options = EmbeddedConversionOptionsV1 {
            engine: Some("piper".to_owned()),
            models_root: Some(root.path().to_string_lossy().into_owned()),
            model_id: Some("pt_BR-edresson-low".to_owned()),
            ..EmbeddedConversionOptionsV1::default()
        };
        assert!(resolve_piper_model_paths(&options).is_err());
        let config = model_dir.join("model.onnx.json");
        std::fs::write(&config, b"{}").unwrap();
        assert_eq!(
            resolve_piper_model_paths(&options).unwrap(),
            (model, config)
        );
    }

    fn fixture() -> tempfile::NamedTempFile {
        fixture_chapters(1)
    }
