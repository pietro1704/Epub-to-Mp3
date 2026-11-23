#[test]
fn conversion_failures_carry_the_additive_error_code_marker() {
    let book = fixture_chapters(1);
    let root = tempfile::tempdir().unwrap();
    let input = CString::new(book.path().to_str().unwrap()).unwrap();
    let output = CString::new(root.path().join("failing-job").to_str().unwrap()).unwrap();
    let job = CString::new("failing-job").unwrap();
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
        // A chapter range with nothing in it leaves no readable text.
        let control = converter_job_control_create();
        let response = converter_session_convert_streaming_job_options_json_v1(
            session,
            output.as_ptr(),
            job.as_ptr(),
            options.as_ptr(),
            5,
            5,
            None,
            None,
            None,
            ptr::null_mut(),
            control,
        );
        converter_job_control_free(control);
        assert!(response.is_null());
        let error = converter_last_error();
        let message = CStr::from_ptr(error).to_string_lossy().into_owned();
        converter_string_free(error);
        converter_session_free(session);
        let (text, marker) = message
            .rsplit_once(" [[error_code_v1]]")
            .unwrap_or_else(|| panic!("no error-code marker in: {message}"));
        assert!(marker.ends_with("[[/error_code_v1]]"), "{message}");
        let code = marker.trim_end_matches("[[/error_code_v1]]");
        assert!(!code.is_empty() && code.chars().all(|c| c.is_ascii_lowercase() || c == '_'));
        assert!(!text.contains("[[error_code_v1]]"), "the marker is appended once");
        assert_eq!(message.matches("[[error_code_v1]]").count(), 1);
        assert_eq!(text, "selected chapters have no readable text", "the human message is unchanged");
        assert_eq!(code, "no_readable_text");
    }
}
