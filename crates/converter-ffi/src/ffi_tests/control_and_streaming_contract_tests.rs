#[test]
fn controlled_ffi_rejects_null_control_and_keeps_null_cleanup_safe() {
    unsafe {
        converter_job_control_free(ptr::null_mut());
        converter_job_control_cancel(ptr::null());
        assert!(!converter_job_control_chapter_is_in_playback_window(
            ptr::null(),
            0
        ));
        assert!(!converter_job_control_prioritize(ptr::null(), 0));
        assert!(!converter_job_control_chapter_is_preempted(ptr::null(), 0));
        assert!(converter_session_convert_streaming_job_options_json_v1(
            ptr::null(),
            ptr::null(),
            ptr::null(),
            c"{}".as_ptr(),
            0,
            -1,
            None,
            None,
            None,
            ptr::null_mut(),
            ptr::null()
        )
        .is_null());
        let error = converter_last_error();
        assert_eq!(
            CStr::from_ptr(error).to_str().unwrap(),
            "invalid null job control"
        );
        converter_string_free(error);
    }
}

#[test]
fn playback_window_query_tracks_runtime_navigation() {
    unsafe {
        let control = converter_job_control_create();
        assert!(!control.is_null());
        converter_job_control_set_playback_window(control, 3, 1);
        assert!(converter_job_control_chapter_is_in_playback_window(
            control, 3
        ));
        assert!(converter_job_control_chapter_is_in_playback_window(
            control, 4
        ));
        assert!(!converter_job_control_chapter_is_in_playback_window(
            control, 2
        ));

        converter_job_control_set_playback_window(control, 7, 1);
        assert!(!converter_job_control_chapter_is_in_playback_window(
            control, 3
        ));
        assert!(converter_job_control_chapter_is_in_playback_window(
            control, 7
        ));
        converter_job_control_free(control);
    }
}

#[test]
fn recovery_options_reject_invalid_identity_before_synthesis_or_job_mutation() {
    let book = fixture();
    let input = CString::new(book.path().to_str().unwrap()).unwrap();
    let root = tempfile::tempdir().unwrap();
    let output = CString::new(root.path().join("successor").to_str().unwrap()).unwrap();
    let predecessor = root.path().join("retained-predecessor");
    std::fs::write(&predecessor, b"retained audio").unwrap();
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
        for invalid in ["", ".", "..", "../foreign", "a/b", "a\\b", "a\0b"] {
            let options = CString::new(
                serde_json::json!({
                    "engine": "system", "recovery_job_id": invalid
                })
                .to_string(),
            )
            .unwrap();
            let control = FixtureJobControl::new();
            let response = converter_session_convert_streaming_job_options_json_v1(
                session,
                output.as_ptr(),
                c"successor".as_ptr(),
                options.as_ptr(),
                0,
                0,
                None,
                None,
                None,
                ptr::null_mut(),
                control.0,
            );
            assert!(response.is_null());
            let error = converter_last_error();
            assert!(!error.is_null());
            assert!(CStr::from_ptr(error).to_string_lossy().contains("recovery"));
            converter_string_free(error);
            assert_eq!((*control.0).control.recover_job(), None);
        }
        converter_session_free(session);
    }
    assert_eq!(calls.load(std::sync::atomic::Ordering::Acquire), 0);
    assert_eq!(std::fs::read(predecessor).unwrap(), b"retained audio");
    assert!(!root.path().join(".jobs").exists());
}

unsafe extern "C" fn queued_test_speech(
    text: *const c_char,
    language: *const c_char,
    output: *const c_char,
    cancelled: ConverterPlatformCancelled,
    cancel_context: *const c_void,
    error: *mut c_char,
    error_length: u32,
    context: *mut c_void,
) -> bool {
    let calls = &*context.cast::<std::sync::atomic::AtomicUsize>();
    if calls.load(std::sync::atomic::Ordering::Acquire) > 0 {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !cancelled(cancel_context) && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        return false;
    }
    platform_test_speech(
        text,
        language,
        output,
        cancelled,
        cancel_context,
        error,
        error_length,
        context,
    )
}

#[test]
fn queued_streaming_publishes_a_real_segment_before_chapter_completion_and_cancels() {
    let book = fixture_chapters_with_text(1, &"A long sentence for progressive audio. ".repeat(80));
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("queued-stream");
    let input = CString::new(book.path().to_str().unwrap()).unwrap();
    let output = CString::new(directory.to_str().unwrap()).unwrap();
    let job = CString::new("queued-stream").unwrap();
    let options = CString::new(r#"{"language":"pt-BR","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null}}}"#).unwrap();
    let calls = std::sync::atomic::AtomicUsize::new(0);
    unsafe {
        let session = converter_session_open(input.as_ptr());
        assert!(!session.is_null());
        assert!(converter_session_set_platform_tts_v1(
            session,
            Some(queued_test_speech),
            (&calls as *const std::sync::atomic::AtomicUsize)
                .cast_mut()
                .cast()
        ));
        let control = converter_job_control_create();
        assert!(converter_job_control_enable_audio_chunks(control));
        let session_address = session as usize;
        let control_address = control as usize;
        std::thread::scope(|scope| {
            let worker = scope.spawn(move || {
                let result = converter_session_convert_streaming_job_options_json_v1(
                    session_address as *const ConverterSession,
                    output.as_ptr(),
                    job.as_ptr(),
                    options.as_ptr(),
                    0,
                    0,
                    None,
                    None,
                    None,
                    ptr::null_mut(),
                    control_address as *const ConverterJobControl,
                );
                let cancelled = result.is_null();
                converter_string_free(result);
                cancelled
            });
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            let event = loop {
                let event = converter_job_control_take_audio_chunk_json(control);
                if !event.is_null() {
                    break event;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "first playable segment must arrive while conversion runs"
                );
                std::thread::sleep(std::time::Duration::from_millis(5));
            };
            let value: serde_json::Value =
                serde_json::from_str(CStr::from_ptr(event).to_str().unwrap()).unwrap();
            converter_string_free(event);
            assert_eq!(value["chapterIndex"], 0);
            assert_eq!(value["chunkIndex"], 0);
            let path = Path::new(value["path"].as_str().unwrap());
            assert!(path.starts_with(directory.join(".streaming")));
            converter_core::pcm::validate_mp3(&std::fs::read(path).unwrap()).unwrap();
            assert!(!directory.join("manifest.json").exists());
            assert!(!worker.is_finished());
            converter_job_control_cancel(control);
            assert!(worker.join().unwrap());
        });
        assert!(converter_job_control_take_audio_chunk_json(control).is_null());
        assert!(!directory.join("manifest.json").exists());
        assert_eq!(
            std::fs::read_dir(directory.join(".streaming"))
                .unwrap()
                .count(),
            1
        );
        assert_eq!(calls.load(std::sync::atomic::Ordering::Acquire), 1);
        converter_session_free(session);
        converter_job_control_free(control);
    }
}

#[test]
fn a_fresh_job_control_preempts_nothing() {
    // The preemption itself (attach, take, prioritize while streaming) is covered in
    // converter-core; here the additive symbol is only checked for a safe default.
    unsafe {
        let control = converter_job_control_create();
        assert!(!control.is_null());
        converter_job_control_set_playback_window(control, 0, 3);
        assert!(!converter_job_control_chapter_is_preempted(control, 0));
        assert!(!converter_job_control_chapter_is_preempted(control, 2));
        converter_job_control_free(control);
    }
}
