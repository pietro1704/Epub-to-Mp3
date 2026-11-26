#![cfg(not(target_arch = "wasm32"))]
#[path = "support/pdf_fixture.rs"]
mod fixture;
use converter_core::{
    config::AppConfig, embedded::EmbeddedConversionSession, paths::resolve_paths_from,
};

#[test]
fn pdf_embedded_session_preserves_metadata_source_text_and_outline_sections() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("book.PDF");
    std::fs::write(
        &input,
        fixture::pdf(true, &["First page", "", "Third page", "Fourth page"]),
    )
    .unwrap();
    let config = AppConfig::from_paths(resolve_paths_from(
        std::collections::HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    ));
    let session = EmbeddedConversionSession::open(&input, Default::default(), config)
        .expect("PDF must open through the actual embedded conversion entry point");
    assert_eq!(session.metadata().title, "PDF fixture");
    assert_eq!(session.metadata().author, "Fixture author");
    assert_eq!(session.metadata().language.as_deref(), Some("pt-BR"));
    let chapters = &session.metadata().chapters;
    assert_eq!(chapters.len(), 2);
    assert_eq!(chapters[0].name, "First section");
    assert!(chapters[0].text.contains("First page"));
    assert_eq!(chapters[1].name, "Second section");
    assert!(chapters[1].text.contains("Third page"));
    assert!(chapters[1].text.contains("Fourth page"));
    assert!(session.structure_verification().verified);
}

/// Turns the pages at `positions` into image-only pages (drawn content, no text layer).
fn pdf_with_image_pages(texts: &[&str], positions: &[usize]) -> Vec<u8> {
    fixture::pdf_with(false, texts, |objects| {
        let image = objects.len() + 1;
        objects.push("<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 3 >>\nstream\nxyz\nendstream".into());
        for position in positions {
            let page = 2 + position * 2;
            objects[page] = objects[page].replace(
                "/Resources <<",
                &format!("/Resources << /XObject << /Im0 {image} 0 R >>"),
            );
            let content = "q 100 0 0 100 20 20 cm /Im0 Do Q";
            objects[page + 1] = format!(
                "<< /Length {} >>\nstream\n{content}\nendstream",
                content.len()
            );
        }
    })
}

fn open_bytes(
    source: &[u8],
) -> Result<EmbeddedConversionSession, converter_core::embedded::EmbeddedConversionError> {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("source.pdf");
    std::fs::write(&path, source).unwrap();
    let config = AppConfig::from_paths(resolve_paths_from(
        std::collections::HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    ));
    EmbeddedConversionSession::open(&path, Default::default(), config)
}

// calibre writes `/CMapName <font>-cmap def` without the slash on the font name.
#[test]
fn pdf_reads_text_through_a_calibre_to_unicode_map() {
    let source = fixture::pdf_with(false, &["x", "x", "x"], |objects| {
        let map = objects.len() + 1;
        let cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapName TimesNewRomanPSMT-cmap def\n/CMapType 2 def\n/CIDSystemInfo <<\n/Registry (Adobe)\n/Ordering (UCS)\n/Supplement 0\n>> def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n3 beginbfchar\n<0001> <004F>\n<0002> <006C>\n<0003> <00E1>\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend";
        objects.push(format!(
            "<< /Length {} >>\nstream\n{cmap}\nendstream",
            cmap.len()
        ));
        objects.push("<< /Type /FontDescriptor /FontName /Synthetic /Flags 4 >>".into());
        objects.push(format!("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Synthetic /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {} 0 R /DW 500 >>", map + 1));
        for page in [2, 4, 6] {
            objects[page] = objects[page].replace(
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                &format!("<< /Type /Font /Subtype /Type0 /BaseFont /Synthetic /Encoding /Identity-H /DescendantFonts [{} 0 R] /ToUnicode {map} 0 R >>", map + 2),
            );
            let content = "BT /F1 12 Tf 50 700 Td <000100020003> Tj ET";
            objects[page + 1] = format!(
                "<< /Length {} >>\nstream\n{content}\nendstream",
                content.len()
            );
        }
    });
    let session = open_bytes(&source).expect("the text layer is selectable");
    assert_eq!(session.metadata().skipped_pages, 0);
    for chapter in &session.metadata().chapters {
        assert_eq!(chapter.text, "Olá");
    }
}

#[test]
fn pdf_without_outline_preserves_blank_page_positions_and_roman_labels() {
    let session = open_bytes(&fixture::pdf(false, &["First", "", "Third", "Fourth"])).unwrap();
    let chapters = &session.metadata().chapters;
    assert_eq!(
        chapters.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
        ["Page i", "Page ii", "Page 1", "Page 2"]
    );
    assert!(chapters[1].text.is_empty());
    assert_eq!(chapters[2].source_path, "page-3");
    assert!(!session.structure_verification().verified);
    assert!(session.structure_verification().requires_confirmation());
}

#[test]
fn pdf_rejects_image_only_and_malformed_documents_without_partial_success() {
    let no_text = open_bytes(&fixture::pdf(false, &["", "", ""]))
        .unwrap_err()
        .to_string();
    assert!(no_text.contains("no readable text"), "{no_text}");
    assert!(open_bytes(b"This is not a PDF").is_err());
    let broken = fixture::pdf_with(false, &["Readable", "", "Third"], |objects| {
        objects[6] =
            "<< /Length 12 /Filter /MissingFilter >>\nstream\ninvalid data\nendstream".into();
    });
    assert!(
        open_bytes(&broken).is_err(),
        "later-page errors must not publish truncated metadata"
    );
}

#[test]
fn pdf_rejects_unmapped_and_cyclic_outline_destinations() {
    let bad = fixture::pdf_with(true, &["First", "Second", "Third"], |objects| {
        let first = objects
            .iter_mut()
            .find(|o| o.contains("/Title (First section)"))
            .unwrap();
        *first = first.replace("/Dest [3 0 R /Fit]", "/Dest [999 0 R /Fit]");
    });
    assert!(open_bytes(&bad)
        .unwrap_err()
        .to_string()
        .contains("outside the document"));
    let cycle = fixture::pdf_with(true, &["First", "Second", "Third"], |objects| {
        let position = objects
            .iter()
            .position(|o| o.contains("/Title (First section)"))
            .unwrap();
        objects[position] = objects[position].replace(
            &format!("/Next {} 0 R", position + 2),
            &format!("/Next {} 0 R", position + 1),
        );
    });
    assert!(open_bytes(&cycle)
        .unwrap_err()
        .to_string()
        .contains("Cyclic"));
}

#[test]
fn pdf_resolves_named_outline_destinations_and_page_label_number_tree() {
    let named = fixture::pdf_with(true, &["First", "Second", "Third"], |objects| {
        objects[0] = objects[0].replace(
            "/Pages 2 0 R",
            "/Pages 2 0 R /Names << /Dests << /Names [(first) [3 0 R /Fit]] >> >>",
        );
        let first = objects
            .iter_mut()
            .find(|o| o.contains("/Title (First section)"))
            .unwrap();
        *first = first.replace("/Dest [3 0 R /Fit]", "/A << /S /GoTo /D (first) >>");
    });
    let session = open_bytes(&named).unwrap();
    assert_eq!(session.metadata().chapters[0].name, "First section");
    assert!(session.metadata().chapters[0].text.contains("Second"));
    let labels = fixture::pdf_with(false, &["First", "Second", "Third"], |objects| {
        objects[0] = objects[0].replace(
            "/Nums [0 << /S /r >> 2 << /S /D /St 1 >>]",
            "/Kids [<< /Nums [0 << /S /A /P (App-) /St 26 >>] >>]",
        );
    });
    let session = open_bytes(&labels).unwrap();
    assert_eq!(
        session
            .metadata()
            .chapters
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>(),
        ["Page App-Z", "Page App-AA", "Page App-BB"]
    );
}

#[test]
fn pdf_preserves_front_matter_before_the_first_outline() {
    let source = fixture::pdf_with(
        true,
        &["Foreword", "Section one", "Section two"],
        |objects| {
            let first = objects
                .iter_mut()
                .find(|o| o.contains("/Title (First section)"))
                .unwrap();
            *first = first.replace("/Dest [3 0 R /Fit]", "/Dest [5 0 R /Fit]");
        },
    );
    let session = open_bytes(&source).unwrap();
    assert_eq!(session.metadata().chapters.len(), 3);
    assert_eq!(session.metadata().chapters[0].name, "Front matter");
    assert!(session
        .structure_verification()
        .warnings
        .iter()
        .any(|warning| warning.code == "PDF_CONTENT_OUTSIDE_TOC"));
    assert!(!session.structure_verification().verified);
    assert!(session.metadata().chapters[0].text.contains("Foreword"));
}

#[test]
fn pdf_reports_password_protection_and_accepts_empty_password_encryption() {
    use pdf_extract::{Document, EncryptionState, EncryptionVersion, Permissions};
    for password in ["secret", ""] {
        let mut doc =
            Document::load_mem(&fixture::pdf(false, &["Readable", "Second", "Third"])).unwrap();
        doc.trailer.set(
            "ID",
            pdf_extract::Object::Array(vec![
                pdf_extract::Object::string_literal("pdf-fixture-id-1"),
                pdf_extract::Object::string_literal("pdf-fixture-id-1"),
            ]),
        );
        let state = EncryptionState::try_from(EncryptionVersion::V1 {
            document: &doc,
            owner_password: "owner",
            user_password: password,
            permissions: Permissions::COPYABLE,
        })
        .unwrap();
        doc.encrypt(&state).unwrap();
        let mut bytes = Vec::new();
        doc.save_to(&mut bytes).unwrap();
        let result = open_bytes(&bytes);
        if password.is_empty() {
            assert!(result.is_ok(), "{result:?}");
        } else {
            assert!(result.unwrap_err().to_string().contains("password"));
        }
    }
}

#[test]
fn pdf_extraction_observes_cancellation_between_pages() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let calls = AtomicUsize::new(0);
    let source = fixture::pdf(false, &["First", "Second", "Third"]);
    let result = converter_core::ingestion::pdf_text::PdfTextIngestion::from_bytes_with_cancel(
        std::path::Path::new("cancelled.pdf"),
        &source,
        &|| calls.fetch_add(1, Ordering::SeqCst) >= 2,
    );
    assert_eq!(
        result.unwrap_err(),
        converter_core::ingestion::IngestionError::Cancelled
    );
    assert_eq!(calls.load(Ordering::SeqCst), 3);
}

#[test]
fn pdf_invalid_page_geometry_is_an_error_not_an_unwind() {
    let source = fixture::pdf_with(false, &["Readable", "Second", "Third"], |objects| {
        objects[2] = objects[2].replace("/MediaBox [0 0 600 800]", "");
    });
    assert!(open_bytes(&source).is_err());
}

/// PDF-COVER-BLOCKS-CONVERSION: an image page inside a text book is skipped, never a rejection.
#[test]
fn pdf_skips_an_image_page_inside_a_mixed_document() {
    let source = pdf_with_image_pages(&["Readable", "", "Last readable page"], &[1]);
    let session = open_bytes(&source).expect("an image page must not reject the whole book");
    let chapters = &session.metadata().chapters;
    assert!(chapters[0].text.contains("Readable"));
    assert!(chapters[1].text.is_empty());
    assert!(chapters[2].text.contains("Last readable page"));
}

/// PDF-COVER-BLOCKS-CONVERSION: an image-only cover must not block a book that has selectable text.
#[test]
fn pdf_with_an_image_only_cover_converts_the_text_pages() {
    let source = pdf_with_image_pages(&["", "Readable", "Last readable page"], &[0]);
    let session = open_bytes(&source).expect("an image cover must not reject the whole book");
    let text: String = session
        .metadata()
        .chapters
        .iter()
        .map(|chapter| chapter.text.as_str())
        .collect();
    assert!(text.contains("Readable"), "{text}");
    assert!(text.contains("Last readable page"), "{text}");
}

/// A scanned book (no page with text) is still refused, and clients localize it
/// from its own code instead of showing the generic failure.
#[test]
fn pdf_without_any_text_page_fails_with_the_ocr_required_code() {
    let source = pdf_with_image_pages(&["", "", ""], &[0, 1, 2]);
    let error = converter_core::book_input::parse_book_source_with_cancel(
        std::path::Path::new("scanned.pdf"),
        &source,
        &|| false,
    )
    .unwrap_err();
    let worker = converter_core::worker::WorkerError::from(error);
    assert_eq!(worker.code(), "pdf_ocr_required", "{worker}");
    assert!(worker
        .message_with_code()
        .ends_with("[[error_code_v1]]pdf_ocr_required[[/error_code_v1]]"));
}

fn ingest(text: &str) -> converter_core::epub::Chapter {
    let book = converter_core::ingestion::pdf_text::PdfTextIngestion::from_bytes(
        std::path::Path::new("lines.pdf"),
        &fixture::pdf(false, &[text, "", ""]),
    )
    .unwrap();
    book.chapters.into_iter().next().unwrap()
}

fn ends_text(chapter: &converter_core::epub::Chapter) -> Vec<String> {
    let chars: Vec<char> = chapter.text.chars().collect();
    let mut start = 0;
    chapter
        .paragraph_ends
        .iter()
        .map(|end| {
            let piece: String = chars[start..*end].iter().collect();
            start = *end;
            piece.trim().to_string()
        })
        .filter(|piece| !piece.is_empty())
        .collect()
}

#[test]
fn pdf_visual_line_breaks_are_soft_and_do_not_split_paragraphs() {
    let chapter = ingest(
        "Era uma vez um reino muito distante onde\nviviam pessoas que gostavam de ler e de con-\nversar sobre os livros antigos da biblioteca.\nOutra frase continua aqui no mesmo paragrafo.",
    );
    assert_eq!(
        ends_text(&chapter),
        vec!["Era uma vez um reino muito distante onde viviam pessoas que gostavam de ler e de conversar sobre os livros antigos da biblioteca. Outra frase continua aqui no mesmo paragrafo."]
    );
}

#[test]
fn pdf_keeps_short_sentence_endings_as_paragraph_breaks() {
    let chapter = ingest(
        "Uma linha longa o bastante para ocupar quase toda a largura tipica da pagina inteira.\nOutra linha longa o bastante para ocupar quase toda a largura tipica da pagina inteira.\nFim curto.\nNovo paragrafo comeca aqui e segue ate ocupar a largura tipica da pagina inteira ok.",
    );
    let ends = ends_text(&chapter);
    assert_eq!(ends.len(), 2, "{ends:?}");
    assert!(ends[0].ends_with("Fim curto."), "{ends:?}");
    assert!(ends[1].ends_with("inteira ok."), "{ends:?}");
}

#[test]
fn pdf_blank_line_is_still_a_paragraph_break() {
    let chapter = ingest("Primeiro paragrafo sem ponto\n\nSegundo paragrafo");
    assert_eq!(ends_text(&chapter).len(), 2);
}
||||||| parent of bf1cef30 (fix(pdf): a bad outline item no longer drops the book; near-textless scans ask for OCR)


fn outline_edit(change: impl Fn(&str, &mut String)) -> Vec<u8> {
    fixture::pdf_with(true, &["First", "Second", "Third"], |objects| {
        for object in objects.iter_mut() {
            if object.contains("/Title (First section)") {
                change("first", object);
            } else if object.contains("/Title (Second section)") {
                change("second", object);
            }
        }
    })
}

#[test]
fn pdf_outline_item_with_a_goto_action_array_resolves() {
    let source = outline_edit(|which, object| {
        if which == "first" {
            *object = object.replace("/Dest [3 0 R /Fit]", "/A << /S /GoTo /D [3 0 R /Fit] >>");
        }
    });
    let session = open_bytes(&source).expect("an /A GoTo array destination must resolve");
    assert_eq!(session.metadata().chapters[0].name, "First section");
}

#[test]
fn pdf_outline_item_without_a_destination_is_skipped_not_fatal() {
    let source = outline_edit(|which, object| {
        if which == "second" {
            let start = object.find("/Dest").unwrap();
            let end = object[start..].find("]").unwrap() + start + 1;
            object.replace_range(start..end, "");
        }
    });
    let session = open_bytes(&source).expect("one bad item must not drop the book");
    assert_eq!(session.metadata().chapters[0].name, "First section");
}

#[test]
fn pdf_outline_items_on_one_page_all_stay_in_the_contents_list() {
    let source = outline_edit(|which, object| {
        if which == "second" {
            *object = object.replace("/Dest [5 0 R /Fit]", "/Dest [3 0 R /Fit]");
        }
    });
    let session = open_bytes(&source).unwrap();
    let toc: Vec<_> = session
        .metadata()
        .toc
        .iter()
        .map(|t| t.title.clone())
        .collect();
    assert_eq!(toc, ["First section", "Second section"]);
}

#[test]
fn pdf_scan_with_a_stray_character_per_page_fails_with_the_ocr_required_code() {
    let pages = ["."; 8];
    let source = fixture::pdf_with(false, &pages, |objects| {
        let image = objects.len() + 1;
        objects.push("<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 3 >>\nstream\nxyz\nendstream".into());
        for position in 0..pages.len() {
            let page = 2 + position * 2;
            objects[page] = objects[page].replace(
                "/Resources <<",
                &format!("/Resources << /XObject << /Im0 {image} 0 R >>"),
            );
            let content = "BT /F1 12 Tf 50 700 Td (.) Tj ET q 100 0 0 100 20 20 cm /Im0 Do Q";
            objects[page + 1] = format!(
                "<< /Length {} >>\nstream\n{content}\nendstream",
                content.len()
            );
        }
    });
    let error = converter_core::book_input::parse_book_source_with_cancel(
        std::path::Path::new("scanned.pdf"),
        &source,
        &|| false,
    )
    .expect_err("a scan with one stray character per page needs OCR, not empty chapters");
    let worker = converter_core::worker::WorkerError::from(error);
    assert_eq!(worker.code(), "pdf_ocr_required", "{worker}");
}
