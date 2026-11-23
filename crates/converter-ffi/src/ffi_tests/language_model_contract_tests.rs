#[test]
fn catalog_languages_are_exposed_as_versioned_json() {
    unsafe {
        let text = converter_tts_catalog_languages_json_v1(c"macos".as_ptr(), 0);
        assert!(!text.is_null());
        let value: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(text).to_str().unwrap()).unwrap();
        converter_string_free(text);
        assert_eq!(value["schema_version"], 1);
        let tags: Vec<_> = value["languages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|language| language["tag"].as_str().unwrap().to_owned())
            .collect();
        assert!(tags.contains(&"pt".to_owned()) && tags.contains(&"en".to_owned()));
        let unsupported = converter_tts_catalog_languages_json_v1(c"plan9".as_ptr(), 0);
        assert!(unsupported.is_null());
        let error = converter_last_error();
        assert!(CStr::from_ptr(error).to_str().unwrap().contains("unsupported platform"));
        converter_string_free(error);
    }
}

#[test]
fn language_model_resolution_round_trips_and_rejects_bad_requests() {
    unsafe {
        let request = CString::new(
            r#"{"schema_version":1,"book_language":"pt-BR","platform":"Macos","installed_model_ids":["pt_BR-faber-medium"]}"#,
        )
        .unwrap();
        let text = converter_tts_resolve_language_model_json_v1(request.as_ptr());
        assert!(!text.is_null());
        let value: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(text).to_str().unwrap()).unwrap();
        converter_string_free(text);
        assert_eq!(value["status"], "selected");
        assert_eq!(value["source"], "automatic");
        assert_eq!(value["selection"]["model_id"], "pt_BR-faber-medium");

        for (body, expected) in [
            (r#"{"schema_version":2,"book_language":"pt","platform":"Macos"}"#, "unsupported language model request schema"),
            (r#"{"schema_version":1,"book_language":" ","platform":"Macos"}"#, "book_language must not be empty"),
            (r#"not json"#, "expected"),
        ] {
            let body = CString::new(body).unwrap();
            assert!(converter_tts_resolve_language_model_json_v1(body.as_ptr()).is_null());
            let error = converter_last_error();
            let message = CStr::from_ptr(error).to_str().unwrap().to_owned();
            converter_string_free(error);
            assert!(message.contains(expected), "{message}");
        }
        assert!(converter_tts_resolve_language_model_json_v1(std::ptr::null()).is_null());
    }
}

#[test]
fn book_language_is_analyzed_from_a_file_before_any_job() {
    let portuguese = "O leitor abre o livro e acompanha a história. As personagens viajam por um país maravilhoso e descobrem uma pequena aldeia onde os amigos estão à sua espera. ".repeat(20);
    let book = fixture_chapters_with_text(3, &portuguese);
    unsafe {
        let path = CString::new(book.path().to_str().unwrap()).unwrap();
        let text = converter_book_language_json_v1(path.as_ptr());
        assert!(!text.is_null());
        let value: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(text).to_str().unwrap()).unwrap();
        converter_string_free(text);
        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["declared"], "en");
        assert!(value["confirmed"].as_str().unwrap().starts_with("pt"));
        assert_eq!(value["inconclusive_samples"], 0);
        assert!(value["languages"].as_array().unwrap().len() == 1);

        let missing = CString::new("/nonexistent/book.epub").unwrap();
        assert!(converter_book_language_json_v1(missing.as_ptr()).is_null());
        let error = converter_last_error();
        assert!(CStr::from_ptr(error).to_str().unwrap().contains("book not found"));
        converter_string_free(error);
        let text_file = tempfile::Builder::new().suffix(".txt").tempfile().unwrap();
        let wrong = CString::new(text_file.path().to_str().unwrap()).unwrap();
        assert!(converter_book_language_json_v1(wrong.as_ptr()).is_null());
        let error = converter_last_error();
        assert!(CStr::from_ptr(error).to_str().unwrap().contains("unsupported book type"));
        converter_string_free(error);
        assert!(converter_book_language_json_v1(std::ptr::null()).is_null());
    }
}
