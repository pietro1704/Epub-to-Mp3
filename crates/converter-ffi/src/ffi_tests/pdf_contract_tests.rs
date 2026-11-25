use super::*;
#[path = "../../../converter-core/tests/support/pdf_fixture.rs"]
mod pdf_fixture;

#[test]
fn pdf_ffi_opens_metadata_and_converts_selected_section_with_platform_callback() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("book.PDF");
    std::fs::write(
        &input,
        pdf_fixture::pdf(
            true,
            &["Uma primeira frase.", "", "A segunda parte do livro."],
        ),
    )
    .unwrap();
    let path = CString::new(input.to_str().unwrap()).unwrap();
    let output = CString::new(root.path().join("pdf-ffi-job").to_str().unwrap()).unwrap();
    let job = CString::new("pdf-ffi-job").unwrap();
    let options = CString::new(r#"{"engine":"system","language":"pt-BR"}"#).unwrap();
    let calls = std::sync::atomic::AtomicUsize::new(0);
    unsafe {
        let session = converter_session_open(path.as_ptr());
        assert!(!session.is_null());
        let metadata = converter_session_metadata_json(session);
        assert!(!metadata.is_null());
        let value: serde_json::Value =
            serde_json::from_slice(CStr::from_ptr(metadata).to_bytes()).unwrap();
        converter_string_free(metadata);
        assert_eq!(value["title"], "PDF fixture");
        assert_eq!(value["chapters"][1]["sourcePath"], "page-3");
        assert_eq!(value["structure"]["verified"], true);
        assert!(converter_session_set_platform_tts_v1(
            session,
            Some(platform_test_speech),
            (&calls as *const std::sync::atomic::AtomicUsize)
                .cast_mut()
                .cast()
        ));
        let response = {
            let control = FixtureJobControl::new();
            converter_session_convert_streaming_job_options_json_v1(
                session,
                output.as_ptr(),
                job.as_ptr(),
                options.as_ptr(),
                1,
                1,
                None,
                None,
                None,
                ptr::null_mut(),
                control.0,
            )
        };
        if response.is_null() {
            let error = converter_last_error();
            let message = CStr::from_ptr(error).to_string_lossy().into_owned();
            converter_string_free(error);
            converter_session_free(session);
            panic!("{message}");
        }
        let value: serde_json::Value =
            serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
        converter_string_free(response);
        converter_session_free(session);
        assert_eq!(value["manifest"]["chapters"].as_array().unwrap().len(), 1);
        assert_eq!(value["manifest"]["chapters"][0]["sourceIndex"], 1);
        assert!(calls.load(std::sync::atomic::Ordering::SeqCst) > 0);
    }
}

#[test]
fn pdf_ffi_failure_clears_on_next_valid_open_without_reusing_old_metadata() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("book.pdf");
    let path = CString::new(input.to_str().unwrap()).unwrap();
    let malformed = pdf_fixture::pdf_with(false, &["Readable", "Second", "Third"], |objects| {
        objects[2] = objects[2].replace("/MediaBox [0 0 600 800]", "");
    });
    std::fs::write(&input, malformed).unwrap();
    unsafe {
        assert!(converter_session_open(path.as_ptr()).is_null());
        let error = converter_last_error();
        assert!(!error.is_null());
        converter_string_free(error);
        std::fs::write(
            &input,
            pdf_fixture::pdf(false, &["New readable text.", "", "Last page."]),
        )
        .unwrap();
        let session = converter_session_open(path.as_ptr());
        assert!(!session.is_null());
        let metadata = converter_session_metadata_json(session);
        assert!(!metadata.is_null());
        let value: serde_json::Value =
            serde_json::from_slice(CStr::from_ptr(metadata).to_bytes()).unwrap();
        converter_string_free(metadata);
        converter_session_free(session);
        assert_eq!(value["chapters"].as_array().unwrap().len(), 3);
        assert_eq!(value["chapters"][2]["name"], "Page 1");
    }
}

/// PDF-COVER-BLOCKS-CONVERSION: Apple clients open the book through
/// `converter_session_open`, so an image-only page must carry its error code
/// there too, or the Converter falls back to the generic failure.
#[test]
fn pdf_ffi_open_of_an_image_only_page_carries_the_ocr_required_code() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("cover.pdf");
    let source = pdf_fixture::pdf_with(false, &["", "Readable", "Last readable page"], |objects| {
        let image = objects.len() + 1;
        objects.push("<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 3 >>\nstream\nxyz\nendstream".into());
        objects[2] = objects[2].replace(
            "/Resources <<",
            &format!("/Resources << /XObject << /Im0 {image} 0 R >>"),
        );
        let content = "q 100 0 0 100 20 20 cm /Im0 Do Q";
        objects[3] = format!(
            "<< /Length {} >>\nstream\n{content}\nendstream",
            content.len()
        );
    });
    std::fs::write(&input, source).unwrap();
    let path = CString::new(input.to_str().unwrap()).unwrap();
    unsafe {
        assert!(converter_session_open(path.as_ptr()).is_null());
        let error = converter_last_error();
        assert!(!error.is_null());
        let message = CStr::from_ptr(error).to_string_lossy().into_owned();
        converter_string_free(error);
        assert!(message.contains("OCR is required"), "{message}");
        assert!(
            message.ends_with(" [[error_code_v1]]pdf_ocr_required[[/error_code_v1]]"),
            "{message}"
        );
        assert_eq!(message.matches("[[error_code_v1]]").count(), 1, "{message}");
    }
}
