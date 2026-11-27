fn call_names(path: &std::path::Path, index: Option<&str>, name: Option<&str>) -> Option<serde_json::Value> {
    let path = CString::new(path.to_str().unwrap()).unwrap();
    let index = index.map(|v| CString::new(v).unwrap());
    let name = name.map(|v| CString::new(v).unwrap());
    unsafe {
        let raw = converter_chapter_names_update_json_v1(
            path.as_ptr(),
            index.as_ref().map_or(ptr::null(), |v| v.as_ptr()),
            name.as_ref().map_or(ptr::null(), |v| v.as_ptr()),
        );
        if raw.is_null() {
            return None;
        }
        let value = serde_json::from_str(CStr::from_ptr(raw).to_str().unwrap()).unwrap();
        converter_string_free(raw);
        Some(value)
    }
}

#[test]
fn chapter_names_persist_overrides_and_reset_to_automatic() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("book/names.json");
    assert_eq!(call_names(&path, None, None).unwrap()["names"], serde_json::json!({}));
    let set = call_names(&path, Some("2"), Some("A Chegada")).unwrap();
    assert_eq!(set["names"]["2"], "A Chegada");
    assert_eq!(call_names(&path, None, None).unwrap()["names"]["2"], "A Chegada");
    assert_eq!(call_names(&path, Some("2"), None).unwrap()["names"], serde_json::json!({}));
    assert!(call_names(&path, Some("2"), Some("two\nlines")).is_none());
    unsafe {
        let error = converter_last_error();
        assert!(!error.is_null());
        converter_string_free(error);
        assert!(converter_chapter_names_update_json_v1(ptr::null(), ptr::null(), ptr::null()).is_null());
    }
}

#[test]
fn filename_cover_json_returns_label_and_colour() {
    let name = CString::new("Meu_livro.pdf").unwrap();
    unsafe {
        let raw = converter_filename_cover_json_v1(name.as_ptr());
        let value: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(raw).to_str().unwrap()).unwrap();
        converter_string_free(raw);
        assert_eq!(value["label"], "Meu livro");
        assert_eq!(value["backgroundRgb"].as_array().unwrap().len(), 3);
    }
}
