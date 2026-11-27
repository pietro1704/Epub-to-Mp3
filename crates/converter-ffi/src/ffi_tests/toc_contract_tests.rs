fn fixture_nav_without_title_page() -> tempfile::NamedTempFile {
    let file = tempfile::Builder::new()
        .suffix(".epub")
        .tempfile()
        .expect("temporary EPUB");
    let item = |id: &str| {
        format!(r#"<item id="{id}" href="{id}.xhtml" media-type="application/xhtml+xml"/>"#)
    };
    let package = format!(
        r#"<package xmlns:dc="x" version="3.0"><metadata><title>Test Book</title><creator>Author</creator><language>en</language></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>{}{}{}</manifest><spine><itemref idref="title"/><itemref idref="one"/><itemref idref="two"/></spine></package>"#,
        item("title"),
        item("one"),
        item("two")
    );
    let page = |heading: &str| format!("<html><body><h1>{heading}</h1><p>Body text.</p></body></html>");
    let entries = vec![
        ("META-INF/container.xml".to_owned(), r#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#.to_owned()),
        ("OEBPS/content.opf".to_owned(), package),
        ("OEBPS/nav.xhtml".to_owned(), r#"<html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="one.xhtml">Part One</a><ol><li><a href="two.xhtml#start">Chapter Two</a></li></ol></li></ol></nav></body></html>"#.to_owned()),
        ("OEBPS/title.xhtml".to_owned(), page("Test Book")),
        ("OEBPS/one.xhtml".to_owned(), page("Part One")),
        ("OEBPS/two.xhtml".to_owned(), page("Chapter Two")),
    ];
    std::fs::write(
        file.path(),
        epub_fixture::epub_bytes(entries, zip::write::SimpleFileOptions::default()),
    )
    .expect("write EPUB");
    file
}

// Linux reader 2026-11-25 (synthetic EPUB): the contents list showed every parsed chapter,
// including a title page the book's nav leaves out, and lost the nav's nesting. The 16e lists
// the nav itself (ReaderTocFlattener), so clients need it with each entry's chapter position.
#[test]
fn metadata_exposes_the_book_toc_additively() {
    let metadata = session_metadata_value(&fixture_nav_without_title_page());
    let names: Vec<_> = metadata["chapters"]
        .as_array()
        .unwrap()
        .iter()
        .map(|chapter| chapter["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names, ["Test Book", "Part One", "Chapter Two"]);
    assert_eq!(
        metadata["toc"],
        serde_json::json!([{
            "title": "Part One",
            "level": 1,
            "chapterIndex": 2,
            "children": [{
                "title": "Chapter Two",
                "level": 2,
                "chapterIndex": 3,
                "fragment": "start",
                "children": [],
            }],
        }])
    );

    let without_nav = session_metadata_value(&fixture_chapters(1));
    assert!(
        without_nav.get("toc").is_none(),
        "a book without a TOC keeps the previous JSON shape, so clients list its chapters"
    );
}
