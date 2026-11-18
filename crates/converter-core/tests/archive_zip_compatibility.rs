#[path = "support/epub_fixture.rs"]
mod epub_fixture;

use std::io::Cursor;

use zip::{write::SimpleFileOptions, CompressionMethod};

#[test]
fn epub_resources_with_legacy_names_follow_unicode_manifest_references() {
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    let mut archive = epub_fixture::epub_bytes([
        ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>"),
        ("OPS/package.opf", "<package><metadata><title>Legacy names</title></metadata><manifest><item id=\"chapter\" href=\"é.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"cover\" href=\"coveré.png\" media-type=\"image/png\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"),
        ("OPS/x.xhtml", "<html><body><h1>Opening</h1><p>Preserved text.</p></body></html>"),
        ("OPS/coverx.png", "cover fixture"),
    ], options);
    use_cp437_name(&mut archive, b"OPS/x.xhtml");
    use_cp437_name(&mut archive, b"OPS/coverx.png");
    let book = converter_core::epub::parse_epub(Cursor::new(archive)).unwrap();
    assert_eq!(book.title, "Legacy names");
    assert_eq!(book.chapters[0].source_path, "OPS/é.xhtml");
    assert_eq!(book.chapters[0].text, "Opening Preserved text.");
    assert_eq!(book.cover.as_deref(), Some(b"cover fixture".as_slice()));
}

fn use_cp437_name(archive: &mut [u8], target: &[u8]) {
    // ZIP filename bytes are outside the payload CRC. CP437 0x82 decodes to é.
    let mut replacements = 0;
    for (signature, flags_offset, length_offset, name_offset) in
        [(b"PK\x03\x04", 6, 26, 30), (b"PK\x01\x02", 8, 28, 46)]
    {
        let starts: Vec<_> = archive
            .windows(4)
            .enumerate()
            .filter_map(|(index, bytes)| (bytes == signature).then_some(index))
            .collect();
        for start in starts {
            let length = u16::from_le_bytes([
                archive[start + length_offset],
                archive[start + length_offset + 1],
            ]) as usize;
            if &archive[start + name_offset..start + name_offset + length] != target {
                continue;
            }
            let flags = u16::from_le_bytes([
                archive[start + flags_offset],
                archive[start + flags_offset + 1],
            ]) & !0x0800;
            archive[start + flags_offset..start + flags_offset + 2]
                .copy_from_slice(&flags.to_le_bytes());
            let index = target.iter().position(|byte| *byte == b'x').unwrap();
            archive[start + name_offset + index] = 0x82;
            replacements += 1;
        }
    }
    assert_eq!(replacements, 2, "local and central filenames must match");
}
