fn library_book(cover: &[u8]) -> tempfile::NamedTempFile {
    let opf = r#"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Quincas Borba</dc:title><dc:creator>Machado de Assis</dc:creator><dc:language>pt-BR</dc:language></metadata><manifest><item id="art" href="art.png" media-type="image/png" properties="cover-image"/><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>"#;
    let bytes = epub_fixture::epub_bytes(
        [
            ("mimetype", b"application/epub+zip".as_slice()),
            (
                "META-INF/container.xml",
                br#"<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#
                    .as_slice(),
            ),
            ("OPS/package.opf", opf.as_bytes()),
            ("OPS/c1.xhtml", b"<html><body><p>Texto.</p></body></html>".as_slice()),
            ("OPS/art.png", cover),
        ],
        zip::write::SimpleFileOptions::default(),
    );
    let mut file = tempfile::Builder::new().suffix(".epub").tempfile().unwrap();
    std::io::Write::write_all(&mut file, &bytes).unwrap();
    file
}

fn library_metadata(path: &std::path::Path) -> Option<serde_json::Value> {
    let path = CString::new(path.to_str().unwrap()).unwrap();
    unsafe {
        let raw = converter_book_library_metadata_json_v1(path.as_ptr());
        if raw.is_null() {
            return None;
        }
        let value = serde_json::from_str(CStr::from_ptr(raw).to_str().unwrap()).unwrap();
        converter_string_free(raw);
        Some(value)
    }
}

#[test]
fn library_metadata_returns_shelf_fields_and_the_declared_cover() {
    let book = library_book(b"\x89PNG\r\n\x1a\ncover");
    let value = library_metadata(book.path()).expect("metadata");
    assert_eq!(value["title"], "Quincas Borba");
    assert_eq!(value["author"], "Machado de Assis");
    assert_eq!(value["language"], "pt-BR");
    assert_eq!(value["coverMimeType"], "image/png");
    assert_eq!(value["coverBase64"], "iVBORw0KGgpjb3Zlcg==");
}

#[test]
fn library_metadata_omits_an_oversized_cover_but_keeps_the_book() {
    let book = library_book(&vec![7u8; 2 * 1024 * 1024 + 1]);
    let value = library_metadata(book.path()).expect("metadata");
    assert_eq!(value["title"], "Quincas Borba");
    assert!(value["coverBase64"].is_null());
    assert!(value["coverMimeType"].is_null());
}

#[test]
fn library_metadata_reports_unreadable_input_through_the_last_error() {
    let missing = std::env::temp_dir().join("missing-library-book.epub");
    assert!(library_metadata(&missing).is_none());
    unsafe {
        let error = converter_last_error();
        assert!(CStr::from_ptr(error).to_str().unwrap().contains("cannot open book"));
        converter_string_free(error);
    }
    let not_epub = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(not_epub.path(), b"plain text").unwrap();
    assert!(library_metadata(not_epub.path()).is_none());
    unsafe { assert!(converter_book_library_metadata_json_v1(ptr::null()).is_null()) };
}

fn library_shelf(request: serde_json::Value) -> Option<serde_json::Value> {
    let request = CString::new(request.to_string()).unwrap();
    unsafe {
        let raw = converter_book_library_shelf_json_v1(request.as_ptr());
        if raw.is_null() {
            return None;
        }
        let value = serde_json::from_str(CStr::from_ptr(raw).to_str().unwrap()).unwrap();
        converter_string_free(raw);
        Some(value)
    }
}

#[test]
fn library_shelf_reports_each_book_and_rejects_invalid_requests() {
    let book = library_book(b"not an image");
    let missing = std::env::temp_dir().join("missing-shelf-book.epub");
    let value = library_shelf(serde_json::json!({ "paths": [missing, book.path()] })).unwrap();
    assert!(value["books"][0]["title"].is_null());
    assert!(value["books"][0]["error"].is_string());
    assert_eq!(value["books"][1]["title"], "Quincas Borba");
    assert_eq!(value["books"][1]["author"], "Machado de Assis");
    assert!(value["books"][1]["error"].is_null());
    assert!(value["books"][1]["coverBase64"].is_null());

    assert!(library_shelf(serde_json::json!({ "paths": [], "coverMaxEdge": 0 })).is_none());
    assert!(library_shelf(serde_json::json!({ "paths": [], "coverMaxEdge": 4096 })).is_none());
    assert!(library_shelf(serde_json::json!({ "books": [] })).is_none());
    unsafe { assert!(converter_book_library_shelf_json_v1(ptr::null()).is_null()) };
}
