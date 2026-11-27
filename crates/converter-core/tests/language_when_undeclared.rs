#![cfg(not(target_arch = "wasm32"))]
//! Books that declare no language get one from their own text, as a BCP 47 tag.
use converter_core::book_input::{parse_book_reader, parse_book_source_with_cancel};
use std::io::{Cursor, Write};
use std::path::Path;

const PORTUGUESE: &str =
    "A menina abriu o livro antigo e começou a ler em voz alta para a família. \
    Durante a noite inteira, ninguém quis interromper aquela história sobre uma cidade esquecida. \
    Quando amanheceu, todos concordaram que precisavam conhecer o restante da narrativa.";

fn epub(declared: &str, body: &str) -> Vec<u8> {
    let opf = format!("<package><metadata><title>Synthetic</title>{declared}</metadata><manifest><item id=\"c\" href=\"c.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c\"/></spine></package>");
    let chapter = format!("<html><body><p>{body}</p></body></html>");
    let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
    for (name, content) in [
        (
            "META-INF/container.xml",
            "<container><rootfiles><rootfile full-path=\"package.opf\"/></rootfiles></container>",
        ),
        ("package.opf", opf.as_str()),
        ("c.xhtml", chapter.as_str()),
    ] {
        zip.start_file(name, zip::write::SimpleFileOptions::default())
            .unwrap();
        zip.write_all(content.as_bytes()).unwrap();
    }
    zip.finish().unwrap().into_inner()
}

fn languages(declared: &str, body: &str) -> [Option<String>; 2] {
    let bytes = epub(declared, body);
    let path = Path::new("synthetic.epub");
    [
        parse_book_source_with_cancel(path, &bytes, &|| false)
            .unwrap()
            .language,
        parse_book_reader(path, Cursor::new(bytes))
            .unwrap()
            .language,
    ]
}

#[test]
fn an_undeclared_language_is_detected_from_the_text() {
    for language in languages("", PORTUGUESE) {
        assert_eq!(language.as_deref(), Some("pt-BR"));
    }
}

#[test]
fn three_letter_declarations_become_bcp47_subtags() {
    for (declared, expected) in [("eng", "en"), ("por-BR", "pt-BR"), ("fre", "fr")] {
        for language in languages(&format!("<language>{declared}</language>"), PORTUGUESE) {
            assert_eq!(language.as_deref(), Some(expected), "{declared}");
        }
    }
}

#[test]
fn text_without_evidence_stays_without_a_language() {
    for language in languages("", "123 456") {
        assert_eq!(language, None);
    }
}
