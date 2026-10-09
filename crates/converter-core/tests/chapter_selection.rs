use converter_core::{
    cache,
    config::AppConfig,
    epub, paths,
    worker::{ConversionRequest, ConversionWorker},
};
use std::{collections::HashMap, fs, io::Write};

#[test]
fn explicit_position_selects_only_the_requested_chapter() {
    let root = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(paths::resolve_paths_from(
        HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    ));
    let worker = ConversionWorker::new(config).unwrap();
    let input = root.path().join("book.epub");
    let mut archive = zip::ZipWriter::new(fs::File::create(&input).unwrap());
    let entries = [
        (
            "META-INF/container.xml",
            r#"<container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>"#,
        ),
        (
            "OEBPS/book.opf",
            r#"<package xmlns:dc="urn:dc"><metadata><dc:title>Selection fixture</dc:title><dc:language>en</dc:language></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>"#,
        ),
        (
            "OEBPS/one.xhtml",
            "<html><body><h1>First</h1><p>The first chapter body.</p></body></html>",
        ),
        (
            "OEBPS/two.xhtml",
            "<html><body><h1>Second</h1><p>The second chapter body.</p></body></html>",
        ),
    ];
    for (name, text) in entries {
        archive
            .start_file(name, zip::write::SimpleFileOptions::default())
            .unwrap();
        archive.write_all(text.as_bytes()).unwrap();
    }
    archive.finish().unwrap();
    let source = fs::read(&input).unwrap();
    let book = epub::parse_epub(std::io::Cursor::new(&source)).unwrap();
    assert!(book.chapters.len() >= 2);
    assert_eq!(book.chapters[0].index, "1");
    let result = worker.run(ConversionRequest {
        input,
        job_id: "selected-second-chapter".into(),
        engine: Some("piper".into()),
        voice: None,
        language: None,
        chapter_indices: Some(vec!["@position:1".into()]),
        no_parallel: true,
    });
    assert!(result.is_err());
    let cache_dir = worker
        .config
        .paths
        .cache_dir
        .join(cache::sha256_bytes(&source));
    let first = cache_dir.join(format!("{}.json", book.chapters[0].index.replace('.', "_")));
    let second = cache_dir.join(format!("{}.json", book.chapters[1].index.replace('.', "_")));
    assert!(
        !first.exists(),
        "the first TOC chapter must remain unselected"
    );
    assert_eq!(
        cache::read_json::<String>(second).unwrap(),
        book.chapters[1].text
    );
}
