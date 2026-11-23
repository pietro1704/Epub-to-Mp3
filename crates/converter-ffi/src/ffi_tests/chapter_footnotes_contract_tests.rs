fn session_metadata_value(file: &tempfile::NamedTempFile) -> serde_json::Value {
    let path = CString::new(file.path().to_str().unwrap()).unwrap();
    unsafe {
        let handle = converter_session_open(path.as_ptr());
        assert!(!handle.is_null());
        let metadata = converter_session_metadata_json(handle);
        let value = serde_json::from_str(CStr::from_ptr(metadata).to_str().unwrap()).unwrap();
        converter_string_free(metadata);
        converter_session_free(handle);
        value
    }
}

#[test]
fn metadata_exposes_chapter_footnotes_additively() {
    let with_note = fixture_chapters_with_text(
        1,
        r##"Claim<a href="#note1">1</a>.</p><aside id="note1">Cited   source.</aside><p>End"##,
    );
    let metadata = session_metadata_value(&with_note);
    assert_eq!(
        metadata["chapters"][0]["footnotes"],
        serde_json::json!([{ "number": "1", "text": "Cited source." }])
    );

    let plain = session_metadata_value(&fixture_chapters(1));
    let chapter = plain["chapters"][0].as_object().unwrap();
    assert!(
        !chapter.contains_key("footnotes"),
        "chapters without notes keep the previous JSON shape"
    );
    let mut keys: Vec<_> = chapter.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        ["index", "level", "name", "sourcePath", "text", "textChars"]
    );
}
