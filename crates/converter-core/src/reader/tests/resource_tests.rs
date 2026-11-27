use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use std::io::{Cursor, Write};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

const PNG: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aTGUAAAAASUVORK5CYII=";

fn archive(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    for (name, content) in entries {
        writer.start_file(*name, options).unwrap();
        writer.write_all(content).unwrap();
    }
    writer.finish().unwrap().into_inner()
}

fn book(chapters: &[(&str, &str)], navigation: Option<&str>, extras: &[(&str, &[u8])]) -> Vec<u8> {
    let mut manifest = String::new();
    let mut spine = String::new();
    for (index, (path, _)) in chapters.iter().enumerate() {
        manifest.push_str(&format!(
            r#"<item id="c{index}" href="{path}" media-type="application/xhtml+xml"/>"#
        ));
        spine.push_str(&format!(r#"<itemref idref="c{index}"/>"#));
    }
    if navigation.is_some() {
        manifest.push_str(r#"<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>"#);
    }
    let opf = format!("<package><metadata><title>Reader fixture</title><creator>Author</creator><language>pt-BR</language></metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>");
    let mut entries = vec![
        (
            "META-INF/container.xml",
            br#"<container><rootfiles><rootfile full-path="package.opf"/></rootfiles></container>"#
                .as_slice(),
        ),
        ("package.opf", opf.as_bytes()),
    ];
    let mut seen = std::collections::HashSet::new();
    for (path, source) in chapters {
        if seen.insert(*path) {
            entries.push((*path, source.as_bytes()));
        }
    }
    if let Some(source) = navigation {
        entries.push(("nav.xhtml", source.as_bytes()));
    }
    entries.extend_from_slice(extras);
    archive(&entries)
}

#[test]
fn inspection_keeps_core_hierarchy_and_resolves_local_assets_and_links() {
    let first = r##"<html lang="pt-BR"><head><link rel="stylesheet" href="styles/book.css"/><link rel="stylesheet" href="https://tracker.invalid/style"/></head><body style="text-align: justify"><h1>Heading fallback</h1><p>Olá <em>café</em>.</p><a href="second%20chapter.xhtml#arr%C3%ADval">Continue</a><a href="#local">Here</a><a name="local">Alias</a><img src="images/dot.png" alt="Dot"/><img src="missing.png" alt="Missing image"/><a href="javascript:alert(1)" data-reader-chapter="999">Forged</a></body></html>"##;
    let nav = r#"<html><body><nav epub:type="toc"><ol><li><a href="first.xhtml">Part</a><ol><li><a href="second chapter.xhtml">Nested chapter</a></li></ol></li></ol></nav></body></html>"#;
    let png = STANDARD.decode(PNG).unwrap();
    let bytes = book(&[("first.xhtml", first), ("second chapter.xhtml", "<h1 id=\"arríval\">Arrival</h1><p>Second</p>")], Some(nav), &[
        ("images/dot.png", &png),
        ("styles/book.css", b"body { color: red; } em { font-weight: bold; } @import 'https://tracker.invalid';"),
    ]);
    let reader = resources::inspect(&bytes).unwrap();
    let legacy = crate::epub::parse_epub(Cursor::new(&bytes)).unwrap();
    assert_eq!(reader.book_title, "Reader fixture");
    assert_eq!(reader.book_author, "Author");
    assert_eq!(reader.language.as_deref(), Some("pt-BR"));
    assert_eq!(
        reader
            .chapters
            .iter()
            .map(|c| c.index.as_str())
            .collect::<Vec<_>>(),
        ["1", "1.1"]
    );
    for (new, old) in reader.chapters.iter().zip(&legacy.chapters) {
        assert_eq!(new.index, old.index);
        assert_eq!(new.name, old.name);
        assert_eq!(new.source_path, old.source_path);
        assert_eq!(new.level, old.level);
    }
    let first = &reader.chapters[0];
    assert!(first.html.contains("data-reader-chapter=\"1.1\""));
    assert!(first.html.contains("data-reader-fragment=\"arríval\""));
    assert!(first.html.contains("data-reader-chapter=\"1\""));
    assert!(first.html.contains(&format!("data:image/png;base64,{PNG}")));
    assert!(first.text.contains("Missing image"));
    assert!(!first.html.contains("999"));
    assert!(!first.html.contains("tracker.invalid"));
    assert!(!first.html.contains("style="));
    assert!(first.css.contains(".reader-root-body"));
    assert!(first.css.contains("text-align: justify"));
    let mut input = request(&first.html);
    input.css = Some(first.css.clone());
    let rendered = render_chapter(input).unwrap();
    assert_eq!(rendered.text, first.text);
    assert!(rendered.anchors.iter().any(|a| a.id == "local"));
    assert!(joined(&rendered).contains("reader-inline-0"));
    assert!(rendered.css.contains(".reader-root-body"));
    let encoded: Value = serde_json::from_str(&inspect_epub_json(&bytes).unwrap()).unwrap();
    assert_eq!(encoded["chapters"][1]["index"], "1.1");
}

#[test]
fn image_only_chapter_is_retained_without_changing_legacy_conversion() {
    let png = STANDARD.decode(PNG).unwrap();
    let bytes = book(
        &[(
            "image.xhtml",
            "<html><body><img src=\"dot.png\" alt=\"Illustration\"/></body></html>",
        )],
        None,
        &[("dot.png", &png)],
    );
    assert!(crate::epub::parse_epub(Cursor::new(&bytes))
        .unwrap()
        .chapters
        .is_empty());
    let reader = resources::inspect(&bytes).unwrap();
    assert_eq!(reader.chapters.len(), 1);
    assert!(reader.chapters[0].text.is_empty());
    let rendered = render(&reader.chapters[0].html);
    assert_eq!(rendered.pages.len(), 1);
    assert!(joined(&rendered).contains("alt=\"Illustration\""));
    assert!(joined(&rendered).contains("data:image/png;base64,"));
}

#[test]
fn reader_only_spine_items_do_not_renumber_convertible_chapter_identities() {
    let png = STANDARD.decode(PNG).unwrap();
    let partial_toc = r#"<html><body><nav epub:type="toc"><ol><li><a href="known.xhtml">Known</a></li></ol></nav></body></html>"#;
    for navigation in [None, Some(partial_toc)] {
        let bytes = book(
            &[
                (
                    "cover.xhtml",
                    "<html><body><img src=\"dot.png\"/></body></html>",
                ),
                ("orphan.xhtml", "<p>Unlisted readable chapter</p>"),
                ("known.xhtml", "<p>Known readable chapter</p>"),
            ],
            navigation,
            &[("dot.png", &png)],
        );
        let legacy = crate::epub::parse_epub(Cursor::new(&bytes)).unwrap();
        let reader = resources::inspect(&bytes).unwrap();
        assert_eq!(legacy.chapters.len(), 2);
        assert_eq!(reader.chapters.len(), 3);
        for converted in legacy.chapters {
            let visible = reader
                .chapters
                .iter()
                .find(|chapter| chapter.source_path == converted.source_path)
                .unwrap();
            assert_eq!(
                visible.index, converted.index,
                "Playback identity changed for {}",
                converted.source_path
            );
        }
        assert_eq!(reader.chapters[0].index, "0.1");
    }
}

#[test]
fn duplicate_identity_corrupt_zip_and_missing_spine_fail() {
    let nav = r#"<nav epub:type="toc"><ol><li><a href="a.xhtml">A</a></li></ol></nav>"#;
    let bytes = book(
        &[("a.xhtml", "<p>A</p>"), ("a.xhtml", "<p>A</p>")],
        Some(nav),
        &[],
    );
    assert!(
        matches!(resources::inspect(&bytes), Err(ReaderError::Invalid(message)) if message.contains("unique"))
    );
    assert!(resources::inspect(b"invalid zip").is_err());
    let mut bytes = book(&[("a.xhtml", "<p>A</p>")], None, &[]);
    bytes.truncate(bytes.len() / 2);
    assert!(resources::inspect(&bytes).is_err());
    let bytes = archive(&[("META-INF/container.xml", b"<container></container>")]);
    assert!(resources::inspect(&bytes).is_err());
}

#[test]
fn deeply_nested_or_stack_confusing_toc_fails_before_legacy_recursion() {
    let deep = format!("{}text{}", "<div>".repeat(130), "</div>".repeat(130));
    let bytes = book(&[("a.xhtml", &deep)], None, &[]);
    assert!(matches!(
        resources::inspect(&bytes),
        Err(ReaderError::Epub(
            crate::epub::EpubError::StructureLimit { .. }
        ))
    ));
    let bytes = archive(&[
        ("META-INF/container.xml", br#"<container><rootfiles><rootfile full-path="package.opf"/></rootfiles></container>"#),
        ("package.opf", br#"<package><manifest><item id="chapter" href="a.xhtml"/><item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="toc"><itemref idref="chapter"/></spine></package>"#),
        ("a.xhtml", b"<p>Readable</p>"),
        ("toc.ncx", b"<ncx><navMap><navPoint><navLabel><text><navPoint></navPoint></text></navLabel></navPoint></navMap></ncx>"),
    ]);
    assert!(matches!(
        resources::inspect(&bytes),
        Err(ReaderError::Epub(
            crate::epub::EpubError::ReaderStructure { .. }
        ))
    ));
}

#[test]
fn paired_void_tags_cannot_drain_the_navigation_depth_budget() {
    let navigation = format!(
        "<nav epub:type=\"toc\"><ol>{}<a href=\"a.xhtml\">Chapter</a>{}</ol></nav>",
        "<li><br></br>".repeat(200),
        "</li>".repeat(200)
    );
    let bytes = book(&[("a.xhtml", "<p>Readable</p>")], Some(&navigation), &[]);
    assert!(matches!(
        resources::inspect(&bytes),
        Err(ReaderError::Epub(crate::epub::EpubError::StructureLimit {
            kind: "depth",
            ..
        }))
    ));
}

#[test]
fn bounded_raster_validation_rejects_remote_svg_animation_and_truncation() {
    assert!(resources::safe_data_image(&format!(
        "data:image/png;base64,{PNG}"
    )));
    for source in [
        "https://example.org/image.png",
        "data:image/svg+xml;base64,PHN2Zz4=",
        "data:text/html;base64,PGltZz4=",
        "data:image/png;base64,invalid",
    ] {
        assert!(!resources::safe_data_image(source));
        let rendered = render(&format!("<img src=\"{source}\" alt=\"Fallback\">"));
        assert_eq!(rendered.text, "Fallback");
        assert!(!joined(&rendered).contains("<img"));
    }
    let mut png = STANDARD.decode(PNG).unwrap();
    png.truncate(33);
    assert!(!resources::safe_data_image(&format!(
        "data:image/png;base64,{}",
        STANDARD.encode(&png)
    )));
    let mut png = STANDARD.decode(PNG).unwrap();
    png[16..20].copy_from_slice(&100_000u32.to_be_bytes());
    assert!(!resources::safe_data_image(&format!(
        "data:image/png;base64,{}",
        STANDARD.encode(&png)
    )));
    let mut png = STANDARD.decode(PNG).unwrap();
    let end = png.len() - 12;
    png.splice(end..end, [0, 0, 0, 0, b'a', b'c', b'T', b'L', 0, 0, 0, 0]);
    assert!(!resources::safe_data_image(&format!(
        "data:image/png;base64,{}",
        STANDARD.encode(&png)
    )));
}

#[test]
fn archive_resource_and_chapter_image_budgets_fail_explicitly() {
    let too_large = "x".repeat(8 * 1024 * 1024 + 1);
    let bytes = book(&[("a.xhtml", &too_large)], None, &[]);
    assert!(matches!(
        resources::inspect(&bytes),
        Err(ReaderError::Epub(
            crate::epub::EpubError::ResourceReadLimit { .. }
        ))
    ));
    let images = "<img src=\"missing.png\" alt=\"Missing\">".repeat(129);
    let bytes = book(&[("a.xhtml", &images)], None, &[]);
    assert!(matches!(
        resources::inspect(&bytes),
        Err(ReaderError::Limit {
            kind: "chapter images",
            ..
        })
    ));
}

#[test]
fn shipped_sample_uses_the_additive_inspector() {
    let bytes = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../ruby_app/rails_gateway/public/sample.epub"
    ));
    let book = resources::inspect(bytes).unwrap();
    assert_eq!(book.book_title, "Test Multi Feature Book");
    assert_eq!(book.chapters.len(), 2);
    // The NCX parent keeps its own href, so the spine resource maps to the parent chapter.
    assert_eq!(book.chapters[0].index, "1");
    let legacy = crate::epub::parse_epub(Cursor::new(bytes)).unwrap();
    assert_eq!(book.chapters[0].index, legacy.chapters[0].index);
    assert!(book.chapters[0].text.contains("experimento"));
    assert!(book.chapters[0].text.contains('\n'));
}

#[test]
fn toc_fragments_become_anchors_on_the_reader_text_axis_without_splitting_the_file() {
    let chapter = r#"<html><body><h2 id="a">Primeiro</h2><p>Texto do primeiro.</p><h2 id="b">Segundo</h2><p>Texto do segundo.</p><a id="c"/><p>Terceiro e ultimo.</p><h2 id="unused">Fora</h2></body></html>"#;
    let nav = r##"<html><body><nav epub:type="toc"><ol><li><a href="c.xhtml#a">A</a></li><li><a href="c.xhtml#b">B</a></li><li><a href="c.xhtml#c">C</a></li></ol></nav></body></html>"##;
    let bytes = book(&[("c.xhtml", chapter)], Some(nav), &[]);
    let reader = resources::inspect(&bytes).unwrap();
    // One file stays one chapter, so identities and saved positions are unchanged.
    assert_eq!(reader.chapters.len(), 1);
    let chapter = &reader.chapters[0];
    let rest = |id: &str| {
        let anchor = chapter
            .anchors
            .iter()
            .find(|a| a.id == id)
            .unwrap_or_else(|| panic!("{id}: {:?}", chapter.anchors));
        chapter.text.chars().skip(anchor.offset).collect::<String>()
    };
    assert!(
        rest("a").trim_start().starts_with("Primeiro"),
        "{:?}",
        rest("a")
    );
    assert!(
        rest("b").trim_start().starts_with("Segundo"),
        "{:?}",
        rest("b")
    );
    assert!(
        rest("c").trim_start().starts_with("Terceiro"),
        "{:?}",
        rest("c")
    );
    // Only ids the TOC points at are exposed.
    assert!(chapter.anchors.iter().all(|a| a.id != "unused"));
}
