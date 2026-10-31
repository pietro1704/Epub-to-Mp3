use super::{first_heading, html_to_text_projection, parse_epub};
use std::io::{Cursor, Write};
use zip::{write::SimpleFileOptions, ZipWriter};

#[test]
fn extracts_heading_and_text_without_language_specific_rules() {
    let html = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body><h2>Пролог</h2><p>Texto inicial.</p></body></html>"#;
    assert_eq!(first_heading(html).as_deref(), Some("Пролог"));
    assert_eq!(html_to_text_projection(html).0, "Пролог Texto inicial.");
}

#[test]
fn parses_prefixed_epub_namespaces_and_preserves_content() {
    let mut cursor = Cursor::new(Vec::new());
    {
        let mut zip = ZipWriter::new(&mut cursor);
        let options = SimpleFileOptions::default();
        zip.start_file("META-INF/container.xml", options).unwrap();
        zip.write_all(br#"<c:container xmlns:c="urn:oasis:names:tc:opendocument:xmlns:container"><c:rootfiles><c:rootfile full-path="OPS/package.opf"/></c:rootfiles></c:container>"#).unwrap();
        zip.start_file("OPS/package.opf", options).unwrap();
        zip.write_all(br#"<opf:package xmlns:opf="http://www.idpf.org/2007/opf"><opf:metadata><dc:title xmlns:dc="x">Livro</dc:title></opf:metadata><opf:manifest><opf:item id="chapter" href="chapter.xhtml" media-type="APPLICATION/XHTML+XML"/></opf:manifest><opf:spine><opf:itemref idref="chapter"/></opf:spine></opf:package>"#).unwrap();
        zip.start_file("OPS/chapter.xhtml", options).unwrap();
        zip.write_all(br#"<x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:body><x:h2>Chapter</x:h2><x:p>Readable content.</x:p></x:body></x:html>"#).unwrap();
        zip.finish().unwrap();
    }
    let book = parse_epub(Cursor::new(cursor.into_inner())).unwrap();
    assert_eq!(book.chapters.len(), 1);
    assert_eq!(book.chapters[0].text, "Chapter Readable content.");
}

fn zip_compatibility_book(compression: zip::CompressionMethod, include_chapter: bool) -> Vec<u8> {
    let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(compression);
    archive
        .start_file("META-INF/container.xml", options)
        .unwrap();
    archive.write_all(br#"<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#).unwrap();
    archive.start_file("OPS/package.opf", options).unwrap();
    archive.write_all(br#"<package><metadata><title>ZIP compatibility</title></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#).unwrap();
    if include_chapter {
        archive.start_file("OPS/chapter.xhtml", options).unwrap();
        archive
            .write_all(b"<html><body><h1>Opening</h1><p>Preserved content.</p></body></html>")
            .unwrap();
    }
    archive.finish().unwrap().into_inner()
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
