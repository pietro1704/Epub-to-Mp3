#[path = "../../tests/support/epub_fixture.rs"]
mod epub_fixture;

use super::{read_library_metadata, LibraryMetadata};
use crate::epub::parse_epub;
use std::io::Cursor;
use zip::write::SimpleFileOptions;

const CONTAINER: &str = r#"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#;
const CHAPTER: &str = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Era uma vez um livro.</p></body></html>"#;
const PNG: &[u8] = b"\x89PNG\r\n\x1a\nfront cover";
const DECOY: &[u8] = b"\x89PNG\r\n\x1a\nback cover";

fn package(metadata: &str, manifest: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">{metadata}</metadata><manifest>{manifest}<item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter1"/></spine></package>"#
    )
}

fn book(opf: &str, resources: &[(&str, &[u8])]) -> Vec<u8> {
    let mut entries: Vec<(&str, &[u8])> = vec![
        ("mimetype", b"application/epub+zip"),
        ("META-INF/container.xml", CONTAINER.as_bytes()),
        ("OEBPS/content.opf", opf.as_bytes()),
        ("OEBPS/chapter1.xhtml", CHAPTER.as_bytes()),
    ];
    entries.extend_from_slice(resources);
    epub_fixture::epub_bytes(entries, SimpleFileOptions::default())
}

fn read(bytes: Vec<u8>) -> LibraryMetadata {
    read_library_metadata(Cursor::new(bytes)).unwrap()
}

const TITLED: &str =
    "<dc:title>Dom Casmurro</dc:title><dc:creator>Machado de Assis</dc:creator><dc:language>pt-BR</dc:language>";

#[test]
fn reads_title_author_and_declared_language_without_a_cover() {
    let metadata = read(book(&package(TITLED, ""), &[]));
    assert_eq!(metadata.title.as_deref(), Some("Dom Casmurro"));
    assert_eq!(metadata.author.as_deref(), Some("Machado de Assis"));
    assert_eq!(metadata.language.as_deref(), Some("pt-BR"));
    assert_eq!((metadata.cover, metadata.cover_mime), (None, None));
}

#[test]
fn epub3_cover_image_property_wins_over_cover_like_names() {
    // The decoy's name says "cover"; only the property declares the cover.
    let manifest = r#"<item id="back" href="images/back-cover.png" media-type="image/png"/><item id="art" href="images/art.png" media-type="image/png" properties="cover-image"/>"#;
    let metadata = read(book(
        &package(TITLED, manifest),
        &[
            ("OEBPS/images/back-cover.png", DECOY),
            ("OEBPS/images/art.png", PNG),
        ],
    ));
    assert_eq!(metadata.cover.as_deref(), Some(PNG));
    assert_eq!(metadata.cover_mime.as_deref(), Some("image/png"));
}

#[test]
fn epub2_meta_cover_resolves_its_manifest_item() {
    let metadata_xml = format!(r#"{TITLED}<meta name="cover" content="front"/>"#);
    let manifest = r#"<item id="back" href="../Images/back-cover.jpg" media-type="image/jpeg"/><item id="front" href="../Images/front.jpg" media-type="image/jpeg"/>"#;
    let metadata = read(book(
        &package(&metadata_xml, manifest),
        &[("Images/back-cover.jpg", DECOY), ("Images/front.jpg", PNG)],
    ));
    assert_eq!(metadata.cover.as_deref(), Some(PNG));
    assert_eq!(metadata.cover_mime.as_deref(), Some("image/jpeg"));
}

#[test]
fn a_named_cover_image_is_the_last_resort() {
    let manifest = r#"<item id="c" href="images/capa.png" media-type="image/png"/>"#;
    let metadata = read(book(
        &package(TITLED, manifest),
        &[("OEBPS/images/capa.png", PNG)],
    ));
    assert_eq!(metadata.cover.as_deref(), Some(PNG));
}

#[test]
fn a_missing_cover_resource_keeps_the_rest_of_the_metadata() {
    let manifest = r#"<item id="art" href="images/missing.png" media-type="image/png" properties="cover-image"/>"#;
    let metadata = read(book(&package(TITLED, manifest), &[]));
    assert_eq!(metadata.title.as_deref(), Some("Dom Casmurro"));
    assert_eq!(metadata.cover, None);
    // The full parser treats the cover as optional in the same way.
    let parsed = parse_epub(Cursor::new(book(&package(TITLED, manifest), &[]))).unwrap();
    assert_eq!(parsed.title, "Dom Casmurro");
    assert_eq!(parsed.cover, None);
}

#[test]
fn the_full_parser_uses_the_declared_cover() {
    let manifest = r#"<item id="back" href="images/back-cover.png" media-type="image/png"/><item id="art" href="images/art.png" media-type="image/png" properties="cover-image"/>"#;
    let parsed = parse_epub(Cursor::new(book(
        &package(TITLED, manifest),
        &[
            ("OEBPS/images/back-cover.png", DECOY),
            ("OEBPS/images/art.png", PNG),
        ],
    )))
    .unwrap();
    assert_eq!(parsed.cover.as_deref(), Some(PNG));
    assert_eq!(parsed.cover_mime.as_deref(), Some("image/png"));
}

#[test]
fn empty_metadata_elements_are_absent_and_invalid_archives_fail() {
    let metadata = read(book(&package("<dc:title>  </dc:title>", ""), &[]));
    assert_eq!(metadata.title, None);
    assert_eq!(metadata.author, None);
    assert!(read_library_metadata(Cursor::new(b"not a zip".to_vec())).is_err());
}
