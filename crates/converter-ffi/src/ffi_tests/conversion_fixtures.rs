struct FixtureJobControl(*mut ConverterJobControl);

impl FixtureJobControl {
    fn new() -> Self {
        let handle = converter_job_control_create();
        assert!(!handle.is_null());
        Self(handle)
    }
}

impl Drop for FixtureJobControl {
    fn drop(&mut self) {
        unsafe { converter_job_control_free(self.0) };
    }
}

fn fixture_chapters(count: usize) -> tempfile::NamedTempFile {
    fixture_chapters_with_text(count, "Hello world.")
}

fn fixture_chapters_with_text(count: usize, text: &str) -> tempfile::NamedTempFile {
    let file = tempfile::Builder::new()
        .suffix(".epub")
        .tempfile()
        .expect("temporary EPUB");
    let manifest = (0..count).map(|index| format!(r#"<item id="chapter{index}" href="chapter{index}.xhtml" media-type="application/xhtml+xml"/>"#)).collect::<String>();
    let spine = (0..count)
        .map(|index| format!(r#"<itemref idref="chapter{index}"/>"#))
        .collect::<String>();
    let package = format!(
        r#"<package xmlns:dc="x"><metadata><title>Test Book</title><creator>Author</creator><language>en</language></metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>"#
    );
    let mut entries = vec![
            ("META-INF/container.xml".to_owned(), r#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#.to_owned()),
            ("OEBPS/content.opf".to_owned(), package),
        ];
    for index in 0..count {
        entries.push((
            format!("OEBPS/chapter{index}.xhtml"),
            format!("<html><body><h1>Chapter {index}</h1><p>{text}</p></body></html>"),
        ));
    }
    std::fs::write(
        file.path(),
        epub_fixture::epub_bytes(entries, zip::write::SimpleFileOptions::default()),
    )
    .unwrap();
    file
}

struct ControlCallbackFixture {
    handle: *mut ConverterJobControl,
    chapters: Vec<usize>,
    cancel_on_first: bool,
    freed: bool,
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
        if fixture.cancel_on_first {
            converter_job_control_cancel(fixture.handle);
        }
        converter_job_control_free(fixture.handle);
        fixture.handle = ptr::null_mut();
        fixture.freed = true;
    }
}

fn fixture_recovery_options(options: &CStr, predecessor: Option<&str>) -> CString {
    let mut captured: serde_json::Value = serde_json::from_slice(options.to_bytes()).unwrap();
    captured["recovery_job_id"] = serde_json::json!(predecessor);
    CString::new(captured.to_string()).unwrap()
}
