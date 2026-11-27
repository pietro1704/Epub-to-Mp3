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

// Parse audit 2026-11-27: promotional pages and copyright files with no TOC entry were folded
// into the chapter before them. Only a file named like a part of that chapter continues it.
#[test]
fn unrelated_spine_files_without_a_toc_entry_stay_separate_chapters() {
    let one = format!("<h1>Um</h1><p>{BODY}</p>");
    let promo = format!("<h1>Outro Livro</h1><p>{BODY}</p>");
    let split = "<p>Continuacao do mesmo arquivo.</p>";
    let two = format!("<h1>Dois</h1><p>{BODY}</p>");
    let b = parsed(book(
        &[
            ("part0001_split_000", &one),
            ("part0001_split_001", split),
            ("promo", &promo),
            ("b", &two),
        ],
        &[("Um", "part0001_split_000.xhtml"), ("Dois", "b.xhtml")],
        &[],
    ));
    let names: Vec<&str> = b.chapters.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["Um", "Outro Livro", "Dois"], "{names:?}");
    assert!(b.chapters[0]
        .text
        .ends_with("Continuacao do mesmo arquivo."));
}

// Parse audit 2026-11-27: Part/Volume divider entries (image-only files) became unmapped and the
// dropped printed contents page carried no reason.
#[test]
fn skipped_documents_are_reported_and_empty_dividers_still_map() {
    let divider = r#"<p><img src="d.png" alt="Parte"/></p>"#;
    let one = format!("<h1>Um</h1><p>{BODY}</p>");
    let printed = r#"<nav epub:type="toc"><ol><li><a href="a.xhtml">Um</a></li></ol></nav>"#;
    let b = parsed(book(
        &[("div", divider), ("a", &one), ("sumario", printed)],
        &[("Parte I", "div.xhtml"), ("Um", "a.xhtml")],
        &[],
    ));
    let reasons: Vec<_> = b
        .skipped_documents
        .iter()
        .map(|d| (d.path.rsplit('/').next().unwrap(), d.reason))
        .collect();
    assert_eq!(
        reasons,
        [
            ("div.xhtml", "EMPTY_DOCUMENT"),
            ("sumario.xhtml", "TOC_DOCUMENT")
        ]
    );
    let check = crate::structure::verify_epub_toc(&b);
    assert_eq!((check.mapped_toc_items, check.total_toc_items), (2, 2));
    assert!(check.verified, "{:?}", check.warnings);
    assert_eq!(check.notes.len(), 2, "{:?}", check.notes);
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

// Parse audit #2 (a): an untitled file before the first TOC entry was named "Chapter N" after
// its spine index.
#[test]
fn untitled_front_file_is_not_named_after_its_spine_index() {
    let front = "<p>Dedicatoria do autor para a familia.</p>";
    let one = format!("<h1>Um</h1><p>{BODY}</p>");
    let b = parsed(book(
        &[("front", front), ("a", &one)],
        &[("Um", "a.xhtml")],
        &[],
    ));
    let first = &b.chapters[0].name;
    assert!(!first.starts_with("Chapter "), "{first:?}");
    assert!(first.starts_with("Dedicatoria"), "{first:?}");
}

// Parse audit #2 (b): numbered body files outside the TOC (part0008, part0009...) are parts of
// the TOC chapter before them, not new top-level chapters.
#[test]
fn numbered_body_files_outside_the_toc_continue_the_toc_chapter() {
    let one = format!("<h1>Obra</h1><p>{BODY}</p>");
    let b = parsed(book(
        &[
            ("part0001", &one),
            ("part0002", "<h2>Capitulo I</h2><p>Mais texto do livro.</p>"),
            (
                "part0003",
                "<h2>Capitulo II</h2><p>Mais texto do livro.</p>",
            ),
            ("part0100", "<h2>Capitulo C</h2><p>Mais texto do livro.</p>"),
        ],
        &[("Obra", "part0001.xhtml")],
        &[],
    ));
    assert_eq!(
        b.chapters.len(),
        1,
        "{:?}",
        b.chapters.iter().map(|c| &c.name).collect::<Vec<_>>()
    );
}

// Parse audit #2 (b): a separate untoc'd file never outranks the TOC entry above it.
#[test]
fn separate_untoc_file_is_not_shallower_than_the_toc_entry_above() {
    let one = format!("<h1>Um</h1><p>{BODY}</p>");
    let promo = format!("<h1>Outro Livro</h1><p>{BODY}</p>");
    let b = parsed(book(
        &[("a", &one), ("promo", &promo)],
        &[("Um", "a.xhtml")],
        &[],
    ));
    assert!(
        b.chapters[1].level >= b.chapters[0].level,
        "{:?}",
        b.chapters.iter().map(|c| c.level).collect::<Vec<_>>()
    );
}
