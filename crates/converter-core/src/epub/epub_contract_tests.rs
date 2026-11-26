#[path = "../../tests/support/epub_fixture.rs"]
pub(super) mod epub_fixture;

use super::{first_heading, html_to_text_projection, parse_epub};
use std::io::Cursor;
use zip::write::SimpleFileOptions;

#[test]
fn extracts_heading_and_text_without_language_specific_rules() {
    let html = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body><h2>Пролог</h2><p>Texto inicial.</p></body></html>"#;
    assert_eq!(first_heading(html).as_deref(), Some("Пролог"));
    assert_eq!(html_to_text_projection(html).0, "Пролог Texto inicial.");
}

#[test]
fn parses_prefixed_epub_namespaces_and_preserves_content() {
    let bytes = epub_fixture::epub_bytes([
        ("META-INF/container.xml", br#"<c:container xmlns:c="urn:oasis:names:tc:opendocument:xmlns:container"><c:rootfiles><c:rootfile full-path="OPS/package.opf"/></c:rootfiles></c:container>"#.as_slice()),
        ("OPS/package.opf", br#"<opf:package xmlns:opf="http://www.idpf.org/2007/opf"><opf:metadata><dc:title xmlns:dc="x">Livro</dc:title></opf:metadata><opf:manifest><opf:item id="chapter" href="chapter.xhtml" media-type="APPLICATION/XHTML+XML"/></opf:manifest><opf:spine><opf:itemref idref="chapter"/></opf:spine></opf:package>"#.as_slice()),
        ("OPS/chapter.xhtml", br#"<x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:body><x:h2>Chapter</x:h2><x:p>Readable content.</x:p></x:body></x:html>"#.as_slice()),
    ], SimpleFileOptions::default());
    let book = parse_epub(Cursor::new(bytes)).unwrap();
    assert_eq!(book.chapters.len(), 1);
    assert_eq!(book.chapters[0].text, "Chapter Readable content.");
}

fn zip_compatibility_book(compression: zip::CompressionMethod, include_chapter: bool) -> Vec<u8> {
    let options = SimpleFileOptions::default().compression_method(compression);
    let mut entries = vec![
        ("META-INF/container.xml", br#"<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#.as_slice()),
        ("OPS/package.opf", br#"<package><metadata><title>ZIP compatibility</title></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#.as_slice()),
    ];
    if include_chapter {
        entries.push((
            "OPS/chapter.xhtml",
            b"<html><body><h1>Opening</h1><p>Preserved content.</p></body></html>".as_slice(),
        ));
    }
    epub_fixture::epub_bytes(entries, options)
}

#[test]
fn zip_upgrade_preserves_stored_and_deflated_epub_identity() {
    for compression in [
        zip::CompressionMethod::Stored,
        zip::CompressionMethod::Deflated,
    ] {
        let book = parse_epub(Cursor::new(zip_compatibility_book(compression, true))).unwrap();
        assert_eq!(book.title, "ZIP compatibility");
        assert_eq!(book.chapters.len(), 1);
        assert_eq!(book.chapters[0].index, "1");
        assert_eq!(book.chapters[0].source_path, "OPS/chapter.xhtml");
        assert_eq!(book.chapters[0].name, "Opening");
        assert_eq!(book.chapters[0].text, "Opening Preserved content.");
    }
}

#[test]
fn zip_upgrade_keeps_missing_resource_and_corrupt_archive_failures() {
    let missing = zip_compatibility_book(zip::CompressionMethod::Deflated, false);
    assert!(matches!(
        parse_epub(Cursor::new(missing)),
        Err(super::EpubError::MissingResource(path)) if path == "OPS/chapter.xhtml"
    ));
    let mut truncated = zip_compatibility_book(zip::CompressionMethod::Stored, true);
    truncated.truncate(truncated.len() / 2);
    assert!(matches!(
        parse_epub(Cursor::new(truncated)),
        Err(super::EpubError::Archive(_))
    ));
}

#[test]
fn rejects_epub_with_different_local_and_central_resource_names() {
    for compression in [
        zip::CompressionMethod::Stored,
        zip::CompressionMethod::Deflated,
    ] {
        let mut archive = zip_compatibility_book(compression, true);
        let name = b"OPS/chapter.xhtml";
        let offset = archive
            .windows(name.len())
            .position(|bytes| bytes == name)
            .unwrap();
        // Change only the first (local-header) name, retaining its byte length.
        // The central directory still advertises the legitimate EPUB resource.
        archive[offset..offset + name.len()].copy_from_slice(b"OPS/hidden!.xhtml");
        let parsed = parse_epub(Cursor::new(archive));
        assert!(
            matches!(parsed, Err(super::EpubError::Archive(_))),
            "{parsed:?}"
        );
    }
}

fn language_book(declared: &str, titlepage_lang: &str, chapter_lang: &str) -> Vec<u8> {
    let opf = format!("<package><metadata><title>Idioma</title>{declared}</metadata><manifest><item id=\"cover\" href=\"titlepage.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"cover\"/><itemref idref=\"chapter\"/></spine></package>");
    let titlepage = format!("<html xml:lang=\"{titlepage_lang}\"><head><title>Cover</title></head><body><div>Cover</div></body></html>");
    let chapter =
        format!("<html{chapter_lang}><body><p>Texto sintético do capítulo.</p></body></html>");
    epub_fixture::epub_bytes([
        ("META-INF/container.xml", br#"<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#.as_slice()),
        ("OPS/package.opf", opf.as_bytes()),
        ("OPS/titlepage.xhtml", titlepage.as_bytes()),
        ("OPS/chapter.xhtml", chapter.as_bytes()),
    ], SimpleFileOptions::default())
}

#[test]
fn the_declared_package_language_wins_over_markup() {
    let bytes = language_book("<language>pt-BR</language>", "en", " lang=\"en\"");
    let book = parse_epub(Cursor::new(bytes)).unwrap();
    assert_eq!(book.language.as_deref(), Some("pt-BR"));
}

#[test]
fn markup_language_fills_a_missing_or_invalid_declaration_and_skips_the_titlepage() {
    for declared in ["", "<language>Portuguese</language>"] {
        let bytes = language_book(declared, "en", " xml:lang=\"es\"");
        let book = parse_epub(Cursor::new(bytes)).unwrap();
        assert_eq!(book.language.as_deref(), Some("es"), "{declared}");
    }
}
