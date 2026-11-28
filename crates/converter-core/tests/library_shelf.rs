#[path = "support/epub_fixture.rs"]
mod epub_fixture;

use converter_core::epub::read_library_shelf;
use image::{DynamicImage, GenericImageView, ImageFormat, Rgb, RgbImage, Rgba, RgbaImage};
use std::io::Cursor;
use std::path::PathBuf;
use zip::write::SimpleFileOptions;

const CONTAINER: &str = r#"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#;

fn book(directory: &std::path::Path, name: &str, cover: Option<&[u8]>) -> PathBuf {
    let item = cover.map_or(
        "",
        |_| r#"<item id="art" href="cover.png" media-type="image/png" properties="cover-image"/>"#,
    );
    let opf = format!(
        r#"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{name}</dc:title></metadata><manifest>{item}</manifest><spine/></package>"#
    );
    let mut entries: Vec<(&str, &[u8])> = vec![
        ("mimetype", b"application/epub+zip"),
        ("META-INF/container.xml", CONTAINER.as_bytes()),
        ("content.opf", opf.as_bytes()),
    ];
    if let Some(cover) = cover {
        entries.push(("cover.png", cover));
    }
    let path = directory.join(format!("{name}.epub"));
    std::fs::write(
        &path,
        epub_fixture::epub_bytes(entries, SimpleFileOptions::default()),
    )
    .unwrap();
    path
}

fn png(image: DynamicImage) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    image.write_to(&mut bytes, ImageFormat::Png).unwrap();
    bytes.into_inner()
}

/// Noise keeps the PNG above the 2 MiB that the single-book shelf call drops.
fn large_cover() -> Vec<u8> {
    let mut seed = 0x2545_f491_u32;
    png(DynamicImage::ImageRgb8(RgbImage::from_fn(
        1200,
        1800,
        |_, _| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            Rgb(seed.to_le_bytes()[..3].try_into().unwrap())
        },
    )))
}

#[test]
fn reads_a_shelf_in_order_with_bounded_jpeg_thumbnails() {
    let directory = tempfile::tempdir().unwrap();
    let large = large_cover();
    assert!(large.len() > 2 * 1024 * 1024);
    let small = png(DynamicImage::ImageRgba8(RgbaImage::from_pixel(
        100,
        150,
        Rgba([0, 0, 0, 0]),
    )));
    let paths = vec![
        book(directory.path(), "large", Some(&large)),
        directory.path().join("missing.epub"),
        book(directory.path(), "small", Some(&small)),
        book(directory.path(), "broken-cover", Some(b"not an image")),
        book(directory.path(), "no-cover", None),
    ];

    let shelf = read_library_shelf(&paths, 480);

    assert_eq!(shelf.len(), paths.len());
    assert!(
        shelf[1].is_err(),
        "one unreadable book must not fail others"
    );
    let titles: Vec<_> = [0, 2, 3, 4]
        .map(|index| shelf[index].as_ref().unwrap().title.clone().unwrap())
        .into();
    assert_eq!(titles, ["large", "small", "broken-cover", "no-cover"]);

    let thumbnail = |index: usize| {
        let metadata = shelf[index].as_ref().unwrap();
        assert_eq!(metadata.cover_mime.as_deref(), Some("image/jpeg"));
        let bytes = metadata.cover.as_deref().unwrap();
        assert_eq!(image::guess_format(bytes).unwrap(), ImageFormat::Jpeg);
        assert!(bytes.len() < 256 * 1024);
        image::load_from_memory(bytes).unwrap()
    };
    assert_eq!(thumbnail(0).dimensions(), (320, 480));
    let transparent = thumbnail(2);
    assert_eq!(transparent.dimensions(), (100, 150), "never upscale");
    assert!(
        transparent
            .to_rgb8()
            .get_pixel(50, 75)
            .0
            .iter()
            .all(|&c| c > 250),
        "transparency is flattened onto white"
    );
    for index in [3, 4] {
        let metadata = shelf[index].as_ref().unwrap();
        assert_eq!((&metadata.cover, &metadata.cover_mime), (&None, &None));
    }
}
