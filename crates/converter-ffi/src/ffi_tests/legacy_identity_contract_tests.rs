    #[test]
    fn legacy_conversion_failures_keep_independent_default_job_identity() {
        const GUARD: &str = "EPUB_LEGACY_JOB_IDENTITY_ISOLATED_TEST";
        if std::env::var(GUARD).as_deref() != Ok("1") {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "tests::legacy_conversion_failures_keep_independent_default_job_identity",
                    "--nocapture",
                    "--test-threads=1",
                ])
                .env(GUARD, "1")
                .env("PATH", "/no-tools")
                .env("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1")
                .env("EDGE_PROXY", "blocked://no-network")
                .env("NO_PROXY", "")
                .env("no_proxy", "")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(String::from_utf8_lossy(&output.stdout)
                .contains("LEGACY_JOB_IDENTITY_ASSERTIONS_COMPLETED"));
            return;
        }
        struct SessionGuard(*mut ConverterSession);
        impl Drop for SessionGuard {
            fn drop(&mut self) {
                unsafe { converter_session_free(self.0) };
            }
        }
        let book = fixture();
        let source = std::fs::read(book.path()).unwrap();
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(root.path().to_str().unwrap()).unwrap();
        let session = SessionGuard(unsafe { converter_session_open(input.as_ptr()) });
        assert!(!session.0.is_null());
        let mut errors = Vec::new();
        for _ in 0..2 {
            unsafe {
                let response =
                    converter_session_convert_json(session.0, output.as_ptr(), i32::MAX, i32::MAX);
                if !response.is_null() {
                    converter_string_free(response);
                    panic!("an absent chapter must fail before synthesis");
                }
                let error = converter_last_error();
                assert!(!error.is_null());
                errors.push(CStr::from_ptr(error).to_string_lossy().into_owned());
                converter_string_free(error);
            }
        }
        assert!(
            errors.iter().all(|error| error.contains("selected chapters have no readable text")),
            "each fresh legacy call must reach chapter validation without an ID collision: {errors:?}"
        );
        let jobs = converter_core::jobs::ConversionJobStore::new(root.path().join(".jobs"))
            .unwrap()
            .list()
            .unwrap();
        assert_eq!(jobs.len(), 2);
        assert_ne!(jobs[0].job_id, jobs[1].job_id);
        assert!(jobs
            .iter()
            .all(|job| job.state == converter_core::jobs::JobState::Failed));
        assert_eq!(std::fs::read(book.path()).unwrap(), source);
        println!("LEGACY_JOB_IDENTITY_ASSERTIONS_COMPLETED");
    }

    fn fixture_chapters(count: usize) -> tempfile::NamedTempFile {
        fixture_chapters_with_text(count, "Hello world.")
    }

    fn fixture_chapters_with_text(count: usize, text: &str) -> tempfile::NamedTempFile {
        let file = tempfile::Builder::new()
            .suffix(".epub")
            .tempfile()
            .expect("temporary EPUB");
        let mut zip = ZipWriter::new(file.reopen().expect("reopen fixture"));
        let options = FileOptions::<()>::default();
        zip.start_file("META-INF/container.xml", options).unwrap();
        zip.write_all(br#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#).unwrap();
        zip.start_file("OEBPS/content.opf", options).unwrap();
        let manifest = (0..count).map(|index| format!(r#"<item id="chapter{index}" href="chapter{index}.xhtml" media-type="application/xhtml+xml"/>"#)).collect::<String>();
        let spine = (0..count)
            .map(|index| format!(r#"<itemref idref="chapter{index}"/>"#))
            .collect::<String>();
        let package = format!(
            r#"<package xmlns:dc="x"><metadata><title>Test Book</title><creator>Author</creator><language>en</language></metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>"#
        );
        zip.write_all(package.as_bytes()).unwrap();
        for index in 0..count {
            zip.start_file(format!("OEBPS/chapter{index}.xhtml"), options)
                .unwrap();
            zip.write_all(
                format!("<html><body><h1>Chapter {index}</h1><p>{text}</p></body></html>")
                    .as_bytes(),
            )
            .unwrap();
        }
        zip.finish().unwrap();
        file
    }

    struct ControlCallbackFixture {
        handle: *mut ConverterJobControl,
        chapters: Vec<usize>,
        cancel_on_first: bool,
        freed: bool,
        recovery_rejected: bool,
    }

    unsafe extern "C" fn controlled_chapter_callback(json: *const c_char, context: *mut c_void) {
        let fixture = &mut *(context as *mut ControlCallbackFixture);
        let event = CStr::from_ptr(json).to_bytes();
        if let Ok(event) = serde_json::from_slice::<serde_json::Value>(event) {
            if let Some(index) = event["chapterIndex"].as_u64() {
                fixture.chapters.push(index as usize);
            }
        }
        if !fixture.freed {
            let late_source = CString::new("late-predecessor").unwrap();
            fixture.recovery_rejected =
                !converter_job_control_set_recovery_job(fixture.handle, late_source.as_ptr());
            if fixture.cancel_on_first {
                converter_job_control_cancel(fixture.handle);
            }
            converter_job_control_free(fixture.handle);
            fixture.handle = ptr::null_mut();
            fixture.freed = true;
        }
    }
