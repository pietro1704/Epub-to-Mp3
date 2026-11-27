//! Spine files versus TOC entries: continuations, title-only files and nav documents.
#[path = "../../tests/support/epub_fixture.rs"]
mod epub_fixture;
use super::{parse_epub, parse_epub_for_reader, Book, EpubReadLimits};
use std::io::Cursor;
use zip::write::SimpleFileOptions;

const BODY: &str = "Texto corrido do capitulo com frases suficientes para narrar.";

/// Builds an EPUB 2 book: `files` are (name, xhtml body) in spine order, `toc` is (title, href).
fn book(files: &[(&str, &str)], toc: &[(&str, &str)], extra: &[(&str, &str)]) -> Vec<u8> {
    let manifest: String = files
        .iter()
        .map(|(n, _)| {
            format!(r#"<item id="{n}" href="{n}.xhtml" media-type="application/xhtml+xml"/>"#)
        })
        .collect();
    let spine: String = files
        .iter()
        .map(|(n, _)| format!(r#"<itemref idref="{n}"/>"#))
        .collect();
    let extra_manifest: String = extra
        .iter()
        .map(|(n, _)| format!(r#"<item id="{n}" href="{n}.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#))
        .collect();
    let points: String = toc
        .iter()
        .enumerate()
        .map(|(i, (t, h))| {
            format!(r#"<navPoint id="p{i}"><navLabel><text>{t}</text></navLabel><content src="{h}"/></navPoint>"#)
        })
        .collect();
    let opf = format!(
        r#"<package><metadata><title>T</title></metadata><manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>{manifest}{extra_manifest}</manifest><spine toc="ncx">{spine}</spine></package>"#
    );
    let ncx = format!(r#"<ncx><navMap>{points}</navMap></ncx>"#);
    let mut entries: Vec<(String, Vec<u8>)> = vec![
        ("META-INF/container.xml".into(), br#"<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#.to_vec()),
        ("OPS/package.opf".into(), opf.into_bytes()),
        ("OPS/toc.ncx".into(), ncx.into_bytes()),
    ];
    for (n, body) in files.iter().chain(extra.iter()) {
        entries.push((
            format!("OPS/{n}.xhtml"),
            format!("<html><body>{body}</body></html>").into_bytes(),
        ));
    }
    epub_fixture::epub_bytes(entries, SimpleFileOptions::default())
}

fn parsed(bytes: Vec<u8>) -> Book {
    parse_epub(Cursor::new(bytes)).unwrap()
}

#[test]
fn spine_file_without_toc_entry_continues_the_previous_chapter() {
    let one = format!("<h1>Um</h1><p>{BODY}</p>");
    let more = "<p>Continuacao sem entrada no sumario.</p>";
    let two = format!("<h1>Dois</h1><p>{BODY}</p>");
    let b = parsed(book(
        &[("a", &one), ("a2", more), ("b", &two)],
        &[("Um", "a.xhtml"), ("Dois", "b.xhtml")],
        &[],
    ));
    let names: Vec<&str> = b.chapters.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["Um", "Dois"], "{names:?}");
    let first = &b.chapters[0];
    assert!(
        first.text.ends_with("Continuacao sem entrada no sumario."),
        "{:?}",
        first.text
    );
    let last = *first.paragraph_ends.last().unwrap();
    assert_eq!(last, first.text.chars().count());
    assert!(
        first.paragraph_ends.windows(2).all(|w| w[0] < w[1]),
        "{:?}",
        first.paragraph_ends
    );
}

#[test]
fn nav_document_is_not_narrated() {
    let one = format!("<h1>Um</h1><p>{BODY}</p>");
    let nav = r#"<nav epub:type="toc"><ol><li><a href="a.xhtml">Um</a></li></ol></nav><p>Sumario narrado por engano.</p>"#;
    let b = parsed(book(
        &[("a", &one), ("nav", nav)],
        &[("Um", "a.xhtml")],
        &[],
    ));
    assert!(
        b.chapters
            .iter()
            .all(|c| !c.text.contains("Sumario narrado")),
        "{:?}",
        b.chapters.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}

#[test]
fn image_divider_with_a_toc_entry_stays_a_chapter_in_reader_mode() {
    let img = r#"<p><img src="d.png" alt="Parte"/></p>"#;
    let bytes = book(
        &[("div", img), ("a", &format!("<h1>Um</h1><p>{BODY}</p>"))],
        &[("Parte", "div.xhtml"), ("Um", "a.xhtml")],
        &[],
    );
    let b = parse_epub_for_reader(Cursor::new(bytes), EpubReadLimits::default()).unwrap();
    let names: Vec<&str> = b.chapters.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["Parte", "Um"], "{names:?}");
}
