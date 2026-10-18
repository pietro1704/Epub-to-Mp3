use std::io::{Cursor, Write};

use converter_core::epub::{parse_epub, parse_epub_with_limits, EpubError, EpubReadLimits};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

const CONTAINER: &[u8] =
    br#"<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#;
const PACKAGE: &[u8] = br#"<package><metadata><title>Bounded book</title><creator>Author</creator><language>pt-BR</language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="cover.jpg" media-type="image/jpeg"/></manifest><spine><itemref idref="chapter"/></spine></package>"#;
const CHAPTER: &[u8] = b"<html><body><h1>Opening</h1><p>Preserved text.</p></body></html>";

fn book_with_cover(cover_bytes: usize) -> Vec<u8> {
    book_with_resources(CHAPTER, cover_bytes, CompressionMethod::Deflated)
}

fn book_with_resources(
    chapter: &[u8],
    cover_bytes: usize,
    compression: CompressionMethod,
) -> Vec<u8> {
    archive_with_package(PACKAGE, chapter, cover_bytes, compression)
}

fn archive_with_package(
    package: &[u8],
    chapter: &[u8],
    cover_bytes: usize,
    compression: CompressionMethod,
) -> Vec<u8> {
    let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(compression);
    for (path, bytes) in [
        ("META-INF/container.xml", CONTAINER),
        ("OPS/package.opf", package),
        ("OPS/chapter.xhtml", chapter),
    ] {
        archive.start_file(path, options).unwrap();
        archive.write_all(bytes).unwrap();
    }
    archive.start_file("OPS/cover.jpg", options).unwrap();
    let block = [0_u8; 8192];
    let mut remaining = cover_bytes;
    while remaining > 0 {
        let count = remaining.min(block.len());
        archive.write_all(&block[..count]).unwrap();
        remaining -= count;
    }
    archive.finish().unwrap().into_inner()
}

#[test]
fn oversized_compressed_cover_is_rejected_before_returning_a_book() {
    let compressed = book_with_cover(32 * 1024 * 1024 + 1);
    assert!(
        compressed.len() < 128 * 1024,
        "fixture must stay small on disk"
    );
    let result = parse_epub(Cursor::new(compressed));
    assert!(
        result.is_err(),
        "an oversized decompressed cover must be rejected"
    );
    let message = result.unwrap_err().to_string();
    assert!(message.contains("limit"), "expected a resource limit error");
    assert!(
        message.contains("OPS/cover.jpg"),
        "identify the rejected resource"
    );
}

#[test]
fn exact_resource_and_total_boundaries_preserve_book_identity() {
    let total = (CONTAINER.len() + PACKAGE.len() + CHAPTER.len() + 512) as u64;
    for compression in [CompressionMethod::Stored, CompressionMethod::Deflated] {
        let source = book_with_resources(CHAPTER, 512, compression);
        let limits = EpubReadLimits {
            max_resource_bytes: 512,
            max_total_bytes: total,
        };
        let book = parse_epub_with_limits(Cursor::new(&source), limits).unwrap();
        assert_eq!(book.title, "Bounded book");
        assert_eq!(book.author, "Author");
        assert_eq!(book.language.as_deref(), Some("pt-BR"));
        assert_eq!(book.chapters.len(), 1);
        assert_eq!(book.chapters[0].name, "Opening");
        assert_eq!(book.chapters[0].source_path, "OPS/chapter.xhtml");
        assert_eq!(book.chapters[0].text, "Opening Preserved text.");
        assert_eq!(book.cover, Some(vec![0; 512]));
        assert_eq!(book.cover_mime.as_deref(), Some("image/jpeg"));
        assert!(matches!(
            parse_epub_with_limits(Cursor::new(source), EpubReadLimits { max_total_bytes: total - 1, ..limits }),
            Err(EpubError::TotalReadLimit { path, limit }) if path == "OPS/cover.jpg" && limit == total - 1
        ));
    }
}

#[test]
fn chapter_and_cover_share_the_resource_limit() {
    for (chapter, cover, expected) in [
        (vec![b'x'; 513], 0, "OPS/chapter.xhtml"),
        (CHAPTER.to_vec(), 513, "OPS/cover.jpg"),
    ] {
        let source = book_with_resources(&chapter, cover, CompressionMethod::Deflated);
        assert!(matches!(
            parse_epub_with_limits(Cursor::new(source), EpubReadLimits { max_resource_bytes: 512, max_total_bytes: 4096 }),
            Err(EpubError::ResourceReadLimit { path, limit: 512 }) if path == expected
        ));
    }
}

#[test]
fn zero_and_maximum_limits_are_checked_without_overflow() {
    let source = book_with_cover(0);
    assert!(matches!(
        parse_epub_with_limits(Cursor::new(&source), EpubReadLimits { max_resource_bytes: 0, max_total_bytes: u64::MAX }),
        Err(EpubError::ResourceReadLimit { path, limit: 0 }) if path == "META-INF/container.xml"
    ));
    assert!(matches!(
        parse_epub_with_limits(Cursor::new(&source), EpubReadLimits { max_resource_bytes: u64::MAX, max_total_bytes: 0 }),
        Err(EpubError::TotalReadLimit { path, limit: 0 }) if path == "META-INF/container.xml"
    ));
    let book = parse_epub_with_limits(
        Cursor::new(source),
        EpubReadLimits {
            max_resource_bytes: u64::MAX,
            max_total_bytes: u64::MAX,
        },
    )
    .unwrap();
    assert_eq!(book.title, "Bounded book");
}

#[test]
fn invalid_utf8_and_missing_resources_keep_their_original_errors() {
    let source = book_with_resources(&[0xff], 0, CompressionMethod::Stored);
    assert!(
        matches!(parse_epub(Cursor::new(source)), Err(EpubError::Open(error)) if error.kind() == std::io::ErrorKind::InvalidData)
    );
    let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
    archive
        .start_file("META-INF/container.xml", SimpleFileOptions::default())
        .unwrap();
    archive.write_all(CONTAINER).unwrap();
    let source = archive.finish().unwrap().into_inner();
    assert!(
        matches!(parse_epub(Cursor::new(source)), Err(EpubError::MissingResource(path)) if path == "OPS/package.opf")
    );
}

#[test]
fn checksum_errors_within_budget_are_not_reported_as_limits() {
    let mut source = book_with_resources(CHAPTER, 0, CompressionMethod::Stored);
    let position = source
        .windows(CHAPTER.len())
        .position(|bytes| bytes == CHAPTER)
        .unwrap();
    source[position] = b'!';
    assert!(
        matches!(parse_epub(Cursor::new(source)), Err(EpubError::Open(error)) if error.kind() == std::io::ErrorKind::InvalidData)
    );
}

#[test]
fn navigation_reads_cannot_bypass_the_resource_budget() {
    for (name, media, properties) in [
        ("nav.xhtml", "application/xhtml+xml", " properties=\"nav\""),
        ("toc.ncx", "application/x-dtbncx+xml", ""),
    ] {
        let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        archive
            .start_file("META-INF/container.xml", options)
            .unwrap();
        archive.write_all(CONTAINER).unwrap();
        archive.start_file("OPS/package.opf", options).unwrap();
        let package = format!("<package><manifest><item id=\"chapter\" href=\"chapter.xhtml\"/><item id=\"nav\" href=\"{name}\" media-type=\"{media}\"{properties}/></manifest><spine><itemref idref=\"chapter\"/></spine></package>");
        archive.write_all(package.as_bytes()).unwrap();
        archive.start_file(format!("OPS/{name}"), options).unwrap();
        let navigation = if name == "nav.xhtml" {
            "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml\">Opening</a></li></ol></nav></body></html>"
        } else {
            "<ncx><navMap><navPoint><navLabel><text>Opening</text></navLabel><content src=\"chapter.xhtml\"/></navPoint></navMap></ncx>"
        };
        archive.write_all(navigation.as_bytes()).unwrap();
        archive.write_all(&[b' '; 1025]).unwrap();
        archive.start_file("OPS/chapter.xhtml", options).unwrap();
        archive.write_all(CHAPTER).unwrap();
        let source = archive.finish().unwrap().into_inner();
        assert!(matches!(
            parse_epub_with_limits(Cursor::new(source), EpubReadLimits { max_resource_bytes: 1024, max_total_bytes: 4096 }),
            Err(EpubError::ResourceReadLimit { path, limit: 1024 }) if path == format!("OPS/{name}")
        ));
    }
}

#[test]
fn repeated_spine_resources_consume_the_total_budget_each_time() {
    let package = String::from_utf8(PACKAGE.to_vec())
        .unwrap()
        .replace("</spine>", "<itemref idref=\"chapter\"/></spine>");
    let source = archive_with_package(package.as_bytes(), CHAPTER, 0, CompressionMethod::Deflated);
    let total = (CONTAINER.len() + package.len() + CHAPTER.len() * 2) as u64;
    let limits = EpubReadLimits {
        max_resource_bytes: 512,
        max_total_bytes: total,
    };
    let book = parse_epub_with_limits(Cursor::new(&source), limits).unwrap();
    assert_eq!(book.chapters.len(), 2);
    assert_eq!(book.chapters[0].text, "Opening Preserved text.");
    assert_eq!(book.chapters[1].text, "Opening Preserved text.");
    assert!(matches!(
        parse_epub_with_limits(Cursor::new(source), EpubReadLimits { max_total_bytes: total - CHAPTER.len() as u64, ..limits }),
        Err(EpubError::TotalReadLimit { path, .. }) if path == "OPS/chapter.xhtml"
    ));
}

#[test]
fn misleading_zip_size_does_not_make_an_oversized_resource_acceptable() {
    let mut source = book_with_resources(CHAPTER, 1025, CompressionMethod::Stored);
    assert_eq!(
        parse_epub(Cursor::new(&source))
            .unwrap()
            .cover
            .unwrap()
            .len(),
        1025
    );
    let name = b"OPS/cover.jpg";
    let central_header = source
        .windows(46 + name.len())
        .position(|entry| entry.starts_with(b"PK\x01\x02") && &entry[46..] == name)
        .unwrap();
    source[central_header + 24..central_header + 28].copy_from_slice(&8_u32.to_le_bytes());
    // The parser budget or ZIP integrity checks must reject dishonest metadata.
    // Either rejection is valid; this does not isolate the actual-read sentinel.
    let result = parse_epub_with_limits(
        Cursor::new(source),
        EpubReadLimits {
            max_resource_bytes: 512,
            max_total_bytes: 4096,
        },
    );
    assert!(
        result.is_err(),
        "forged resource size must not yield a book"
    );
}
