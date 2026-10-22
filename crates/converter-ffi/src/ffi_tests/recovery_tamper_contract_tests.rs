    #[test]
    fn controlled_ffi_recovery_resynthesizes_when_predecessor_audio_hash_differs() {
        assert_recovery_resynthesizes_after_tampering(|audio| {
            let receipt = audio.with_extension("mp3.complete.json");
            let original_receipt = std::fs::read(&receipt).unwrap();
            let mut bytes = std::fs::read(audio).unwrap();
            let original_len = bytes.len();
            *bytes
                .last_mut()
                .expect("predecessor contains actual MP3 bytes") ^= 1;
            std::fs::write(audio, &bytes).unwrap();
            assert_eq!(std::fs::metadata(audio).unwrap().len(), original_len as u64);
            assert_eq!(std::fs::read(receipt).unwrap(), original_receipt);
        });
    }

    #[test]
    fn controlled_ffi_recovery_resynthesizes_when_predecessor_receipt_is_corrupt() {
        assert_recovery_resynthesizes_after_tampering(|audio| {
            std::fs::write(
                audio.with_extension("mp3.complete.json"),
                b"corrupt receipt",
            )
            .unwrap();
        });
    }

    #[cfg(unix)]
    #[test]
    fn controlled_ffi_recovery_does_not_follow_a_predecessor_directory_symlink() {
        let outside = tempfile::tempdir().unwrap();
        assert_recovery_resynthesizes_after_tampering(|audio| {
            let directory = audio.parent().unwrap();
            let external = outside.path().join("external-job");
            std::fs::rename(directory, &external).unwrap();
            std::os::unix::fs::symlink(external, directory).unwrap();
        });
    }

    #[cfg(unix)]
    #[test]
    fn controlled_ffi_recovery_does_not_follow_a_predecessor_audio_symlink() {
        let outside = tempfile::tempdir().unwrap();
        assert_recovery_resynthesizes_after_tampering(|audio| {
            let external = outside.path().join("external.mp3");
            std::fs::rename(audio, &external).unwrap();
            std::os::unix::fs::symlink(external, audio).unwrap();
        });
    }

    #[cfg(unix)]
    #[test]
    fn controlled_ffi_recovery_does_not_follow_a_predecessor_receipt_symlink() {
        let outside = tempfile::tempdir().unwrap();
        assert_recovery_resynthesizes_after_tampering(|audio| {
            let receipt = audio.with_extension("mp3.complete.json");
            let external = outside.path().join("external-receipt.json");
            std::fs::rename(&receipt, &external).unwrap();
            std::os::unix::fs::symlink(external, receipt).unwrap();
        });
    }

    fn assert_recovery_resynthesizes_after_tampering(tamper: impl FnOnce(&Path)) {
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
            let convert = |job: &str, recover: bool| {
                let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
                let job_id = CString::new(job).unwrap();
                let control = converter_job_control_create();
                assert!(!control.is_null());
                if recover {
                    let source = CString::new("tampered-predecessor").unwrap();
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
                if response.is_null() {
                    let error = converter_last_error();
                    let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                    converter_string_free(error);
                    panic!("Local tampering fixture {job} failed: {message}");
                }
                let value: serde_json::Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                converter_string_free(response);
                value
            };
            let original = convert("tampered-predecessor", false);
            let original_calls = calls.load(std::sync::atomic::Ordering::Acquire);
            assert!(original_calls > 0);
            let audio = Path::new(original["audioPath"].as_str().unwrap());
            tamper(audio);
            let predecessor_audio = std::fs::read(audio).unwrap();
            let receipt = audio.with_extension("mp3.complete.json");
            let predecessor_receipt = std::fs::read(&receipt).unwrap();
            let job_path = root.path().join(".jobs/tampered-predecessor.json");
            let predecessor_state = std::fs::read(&job_path).unwrap();

            let recovered = convert("tampered-successor", true);
            converter_session_free(session);
            assert!(
                calls.load(std::sync::atomic::Ordering::Acquire) > original_calls,
                "Untrusted predecessor artifacts must fall back to fresh synthesis"
            );
            let recovered_audio = Path::new(recovered["audioPath"].as_str().unwrap());
            assert!(recovered_audio.starts_with(root.path().join("tampered-successor")));
            converter_core::pcm::validate_mp3(&std::fs::read(recovered_audio).unwrap()).unwrap();
            assert_eq!(std::fs::read(audio).unwrap(), predecessor_audio);
            assert_eq!(std::fs::read(receipt).unwrap(), predecessor_receipt);
            assert_eq!(std::fs::read(job_path).unwrap(), predecessor_state);
        }
    }
