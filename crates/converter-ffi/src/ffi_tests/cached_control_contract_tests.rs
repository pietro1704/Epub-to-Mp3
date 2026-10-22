    #[test]
    fn controlled_ffi_priority_and_handle_release_preserve_the_active_worker() {
        run_cached_controlled_ffi(false);
    }

    #[test]
    fn controlled_ffi_cancellation_stops_after_validated_cached_chapter() {
        run_cached_controlled_ffi(true);
    }

    #[test]
    fn legacy_controlled_ffi_persists_pre_cancelled_job_without_synthesis() {
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("pre-cancelled-job");
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(directory.to_str().unwrap()).unwrap();
        let job_id = CString::new("pre-cancelled-job").unwrap();
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
            let control = converter_job_control_create();
            assert!(!control.is_null());
            converter_job_control_cancel(control);
            let response = converter_session_convert_controlled_job_json(
                session,
                output.as_ptr(),
                job_id.as_ptr(),
                0,
                -1,
                None,
                None,
                ptr::null_mut(),
                control,
            );
            assert!(response.is_null());
            let error = converter_last_error();
            let message = CStr::from_ptr(error).to_string_lossy().into_owned();
            converter_string_free(error);
            assert!(message.contains("cancelled"), "actual error: {message}");
            assert_eq!(calls.load(std::sync::atomic::Ordering::Relaxed), 0);
            let job: serde_json::Value = serde_json::from_slice(
                &std::fs::read(root.path().join(".jobs/pre-cancelled-job.json")).unwrap(),
            )
            .unwrap();
            assert_eq!(job["state"], "cancelled");
            assert!(!directory.join("manifest.json").exists());
            converter_job_control_free(control);
            converter_session_free(session);
        }
    }

    fn run_cached_controlled_ffi(cancel_on_first: bool) {
        let book = fixture_chapters(3);
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("controlled-job");
        std::fs::create_dir_all(&directory).unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(directory.to_str().unwrap()).unwrap();
        let job_id = CString::new("controlled-job").unwrap();
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
            // Populate validated audio and request receipts through the real FFI
            // pipeline. A bare WAV with an MP3 suffix is not a reusable cache.
            let warm = converter_session_convert_job_options_json_v1(
                session,
                output.as_ptr(),
                job_id.as_ptr(),
                options.as_ptr(),
                0,
                -1,
                None,
                None,
                ptr::null_mut(),
            );
            assert!(!warm.is_null(), "offline fixture conversion must succeed");
            converter_string_free(warm);
            assert!(calls.load(std::sync::atomic::Ordering::Relaxed) > 0);
            let cached_audio: Vec<_> = std::fs::read_dir(&directory)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .filter(|path| path.extension() == Some(std::ffi::OsStr::new("mp3")))
                .map(|path| {
                    converter_core::audio::validate_audio(&path, 1).unwrap();
                    let receipt = path.with_extension("mp3.complete.json");
                    let bytes = std::fs::read(&path).unwrap();
                    let receipt_bytes = std::fs::read(&receipt).unwrap();
                    (path, bytes, receipt, receipt_bytes)
                })
                .collect();
            assert_eq!(cached_audio.len(), 3);
            // Retain artifacts while simulating recovery without a job record.
            std::fs::remove_file(root.path().join(".jobs/controlled-job.json")).unwrap();
            calls.store(0, std::sync::atomic::Ordering::Relaxed);
            let control = converter_job_control_create();
            assert!(!control.is_null());
            assert!(converter_job_control_prioritize(control, 2));
            let mut fixture = ControlCallbackFixture {
                handle: control,
                chapters: Vec::new(),
                cancel_on_first,
                freed: false,
                recovery_rejected: false,
            };
            let response = converter_session_convert_streaming_job_options_json_v1(
                session,
                output.as_ptr(),
                job_id.as_ptr(),
                options.as_ptr(),
                0,
                -1,
                None,
                Some(controlled_chapter_callback),
                None,
                &mut fixture as *mut ControlCallbackFixture as *mut c_void,
                control,
            );
            if cancel_on_first {
                assert!(response.is_null());
                let error = converter_last_error();
                let error_text = CStr::from_ptr(error).to_str().unwrap().to_owned();
                converter_string_free(error);
                assert!(
                    error_text.contains("cancelled"),
                    "actual controlled conversion error: {error_text}"
                );
                assert_eq!(fixture.chapters, [2]);
            } else {
                if response.is_null() {
                    let error = converter_last_error();
                    let error_text = CStr::from_ptr(error).to_str().unwrap().to_owned();
                    converter_string_free(error);
                    panic!("actual controlled conversion error: {error_text}");
                }
                assert_eq!(fixture.chapters, [2, 0, 1]);
                converter_string_free(response);
            }
            assert!(
                fixture.freed,
                "The worker must own its control clone after the caller releases the handle"
            );
            assert!(
                fixture.recovery_rejected,
                "Recovery source cannot change after queue attachment"
            );
            assert_eq!(
                calls.load(std::sync::atomic::Ordering::Relaxed),
                0,
                "controlled conversion must reuse verified audio without synthesis"
            );
            for (path, bytes, receipt, receipt_bytes) in cached_audio {
                assert_eq!(std::fs::read(path).unwrap(), bytes);
                assert_eq!(std::fs::read(receipt).unwrap(), receipt_bytes);
            }
            let job: serde_json::Value = serde_json::from_slice(
                &std::fs::read(root.path().join(".jobs/controlled-job.json")).unwrap(),
            )
            .unwrap();
            assert_eq!(
                job["state"],
                if cancel_on_first {
                    "cancelled"
                } else {
                    "completed"
                }
            );
            converter_session_free(session);
        }
    }
