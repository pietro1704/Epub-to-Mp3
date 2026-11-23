use super::tests::epub_fixture;
use super::{parse_epub, Footnote};
use std::io::Cursor;
use zip::write::SimpleFileOptions;

const CONTAINER: &str =
    r#"<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#;

fn package(spine: &[&str]) -> String {
    let items: String = spine
        .iter()
        .enumerate()
        .map(|(i, href)| {
            format!(r#"<item id="c{i}" href="{href}" media-type="application/xhtml+xml"/>"#)
        })
        .collect();
    let refs: String = (0..spine.len())
        .map(|i| format!(r#"<itemref idref="c{i}"/>"#))
        .collect();
    format!(
        r#"<package><metadata><title>Notes</title></metadata><manifest>{items}</manifest><spine>{refs}</spine></package>"#
    )
}

fn book(documents: Vec<(&str, String)>, spine: &[&str]) -> crate::epub::Book {
    let package = package(spine);
    let mut entries: Vec<(String, Vec<u8>)> = vec![
        (
            "META-INF/container.xml".into(),
            CONTAINER.as_bytes().to_vec(),
        ),
        ("OPS/package.opf".into(), package.into_bytes()),
    ];
    for (path, body) in documents {
        entries.push((path.into(), body.into_bytes()));
    }
    parse_epub(Cursor::new(epub_fixture::epub_bytes(
        entries,
        SimpleFileOptions::default(),
    )))
    .unwrap()
}

fn note(number: &str, text: &str) -> Footnote {
    Footnote {
        number: Some(number.into()),
        text: text.into(),
    }
}

#[test]
fn extracts_a_note_in_the_same_chapter() {
    let html = r##"<html><body><h1>One</h1><p>Claim<a href="#note1">1</a>.</p>
        <aside id="note1"><p>The   source
        is cited.</p></aside></body></html>"##;
    let book = book(vec![("OPS/a.xhtml", html.into())], &["a.xhtml"]);
    assert_eq!(
        book.chapters[0].footnotes,
        vec![note("1", "The source is cited.")]
    );
}

#[test]
fn extracts_notes_from_a_separate_file_with_relative_paths() {
    let chapter = r##"<html><body><h1>One</h1><p>A<a href="../OPS/notes.xhtml#note-2">2</a>
        B<a href="notes.xhtml#note-3">[3]</a></p></body></html>"##;
    let notes = r##"<html><body><ol><li id="note-2">Second note.</li>
        <li id="note-3"><b>Third</b> note.</li></ol></body></html>"##;
    let book = book(
        vec![
            ("OPS/a.xhtml", chapter.into()),
            ("OPS/notes.xhtml", notes.into()),
        ],
        &["a.xhtml", "notes.xhtml"],
    );
    assert_eq!(
        book.chapters[0].footnotes,
        vec![note("2", "Second note."), note("[3]", "Third note.")]
    );
}

#[test]
fn ignores_ordinary_links_and_chapters_without_notes() {
    let linked = r##"<html><body><h1>One</h1><p><a href="#intro">see intro</a>
        <a href="https://example.com/#footnote">web</a><a href="other.xhtml#part">next</a></p>
        <p id="intro">Intro.</p></body></html>"##;
    let plain = "<html><body><h1>Two</h1><p>No links.</p></body></html>";
    let book = book(
        vec![
            ("OPS/a.xhtml", linked.into()),
            ("OPS/b.xhtml", plain.into()),
        ],
        &["a.xhtml", "b.xhtml"],
    );
    assert!(book.chapters[0].footnotes.is_empty());
    assert!(book.chapters[1].footnotes.is_empty());
}

#[test]
fn skips_missing_targets_and_deduplicates_repeated_references() {
    let html = r##"<html><body><h1>One</h1>
        <p>X<a href="#note1">1</a> Y<a href="#note1">1</a> Z<a href="missing.xhtml#note9">9</a>
        <a href="#note-nowhere">7</a></p><div id="note1">Only once.</div></body></html>"##;
    let book = book(vec![("OPS/a.xhtml", html.into())], &["a.xhtml"]);
    assert_eq!(book.chapters[0].footnotes, vec![note("1", "Only once.")]);
}

#[test]
fn drops_empty_notes_and_labels_and_cuts_long_bodies_on_a_character_boundary() {
    let long = "é".repeat(10_000);
    let html = format!(
        r##"<html><body><h1>One</h1><p><a href="#note1"></a><a href="#note2">2</a><a href="#note3">3</a></p>
        <div id="note1">Unlabelled note.</div><div id="note2"> </div><div id="note3">{long}</div></body></html>"##
    );
    let book = book(vec![("OPS/a.xhtml", html)], &["a.xhtml"]);
    let notes = &book.chapters[0].footnotes;
    assert_eq!(notes.len(), 2);
    assert_eq!(
        notes[0],
        Footnote {
            number: None,
            text: "Unlabelled note.".into()
        }
    );
    assert_eq!(notes[1].number.as_deref(), Some("3"));
    assert!(notes[1].text.len() <= 8 * 1024 && notes[1].text.chars().all(|c| c == 'é'));
}

#[test]
fn refuses_targets_outside_the_archive_and_absolute_paths() {
    let html = r##"<html><body><h1>One</h1><p><a href="../../secret.xhtml#footnote">1</a>
        <a href="/abs/notes.xhtml#footnote">2</a></p></body></html>"##;
    let book = book(vec![("OPS/a.xhtml", html.into())], &["a.xhtml"]);
    assert!(book.chapters[0].footnotes.is_empty());
}

#[test]
fn only_note_like_targets_count_like_the_apple_fallback() {
    let html = r##"<html><body><h1>One</h1><p><a href="#fn1">1</a><a href="#ref7">7</a></p>
        <div id="fn1">Unmarked id.</div><div id="ref7">Also unmarked.</div></body></html>"##;
    let book = book(vec![("OPS/a.xhtml", html.into())], &["a.xhtml"]);
    assert!(book.chapters[0].footnotes.is_empty());
}
