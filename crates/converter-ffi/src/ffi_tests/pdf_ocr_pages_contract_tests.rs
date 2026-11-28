mod pdf_ocr_fixture {
    include!("../../../converter-core/tests/support/pdf_fixture.rs");
}

fn image_page_pdf(scanned: bool) -> Vec<u8> {
    let texts: Vec<&str> = if scanned {
        vec!["", "", ""]
    } else {
        vec![
            "Primeira pagina com texto proprio e suficiente para narrar.",
            "Segunda pagina com outro texto bem diferente do primeiro.",
            "",
        ]
    };
    let last = texts.len() - 1;
    pdf_ocr_fixture::pdf_with(false, &texts, |objects| {
        for page in 0..=last {
            if texts[page].is_empty() {
                let content = "/Fm0 Do";
                objects[2 + page * 2 + 1] = format!(
                    "<< /Length {} >>\nstream\n{content}\nendstream",
                    content.len()
                );
            }
        }
    })
}

fn image_pages_json(bytes: &[u8]) -> serde_json::Value {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("scan.pdf");
    std::fs::write(&input, bytes).unwrap();
    let path = CString::new(input.to_str().unwrap()).unwrap();
    unsafe {
        let raw = converter_pdf_image_pages_json_v1(path.as_ptr());
        assert!(!raw.is_null(), "image pages must be listed");
        let value = serde_json::from_str(CStr::from_ptr(raw).to_str().unwrap()).unwrap();
        converter_string_free(raw);
        value
    }
}

#[test]
fn pdf_image_pages_json_lists_pages_without_a_text_layer() {
    assert_eq!(image_pages_json(&image_page_pdf(false))["pages"], serde_json::json!([3]));
}

#[test]
fn pdf_image_pages_json_lists_every_page_of_a_fully_scanned_pdf() {
    assert_eq!(image_pages_json(&image_page_pdf(true))["pages"], serde_json::json!([1, 2, 3]));
}

#[test]
fn pdf_image_pages_json_is_empty_for_a_text_pdf() {
    let text = pdf_ocr_fixture::pdf(
        false,
        &["Uma primeira frase.", "", "A segunda parte do livro."],
    );
    assert_eq!(image_pages_json(&text)["pages"], serde_json::json!([]));
}
