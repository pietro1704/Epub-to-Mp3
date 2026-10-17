use std::io::{Cursor, Write};

use converter_core::archive::{extract_member, list_members, ArchiveError, ArchiveMember};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

fn fixture(compression: CompressionMethod, name: &str) -> Vec<u8> {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    writer
        .start_file(
            name,
            SimpleFileOptions::default().compression_method(compression),
        )
        .unwrap();
    writer.write_all(b"chapter content").unwrap();
    writer.finish().unwrap().into_inner()
}

#[test]
fn stored_and_deflated_members_keep_their_names_sizes_and_bytes() {
    for compression in [CompressionMethod::Stored, CompressionMethod::Deflated] {
        let archive = fixture(compression, "pages/2.txt");
        assert_eq!(
            list_members(Cursor::new(&archive)).unwrap(),
            vec![ArchiveMember {
                name: "pages/2.txt".into(),
                size: 15,
            }]
        );
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("extracted/chapter.txt");
        extract_member(Cursor::new(&archive), "pages/2.txt", &output).unwrap();
        assert_eq!(std::fs::read(output).unwrap(), b"chapter content");
    }
}

#[test]
fn traversal_members_are_rejected_before_output_is_created() {
    let archive = fixture(CompressionMethod::Deflated, "../outside.txt");
    let directory = tempfile::tempdir().unwrap();
    let output = directory.path().join("extracted/chapter.txt");
    assert!(matches!(
        list_members(Cursor::new(&archive)),
        Err(ArchiveError::UnsafeMember(name)) if name == "../outside.txt"
    ));
    assert!(matches!(
        extract_member(Cursor::new(&archive), "../outside.txt", &output),
        Err(ArchiveError::UnsafeMember(name)) if name == "../outside.txt"
    ));
    assert!(!output.exists());
    assert!(!directory.path().join("extracted").exists());
}

#[test]
fn legacy_cp437_member_names_remain_addressable_by_their_unicode_name() {
    let mut archive = fixture(CompressionMethod::Stored, "x.txt");
    use_cp437_name(&mut archive, b"x.txt");
    assert_eq!(
        list_members(Cursor::new(&archive)).unwrap()[0].name,
        "é.txt"
    );
    let directory = tempfile::tempdir().unwrap();
    let output = directory.path().join("chapter.txt");
    extract_member(Cursor::new(&archive), "é.txt", &output).unwrap();
    assert_eq!(std::fs::read(output).unwrap(), b"chapter content");
}

#[test]
fn epub_resources_with_legacy_names_follow_unicode_manifest_references() {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    for (name, content) in [
        ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>"),
        ("OPS/package.opf", "<package><metadata><title>Legacy names</title></metadata><manifest><item id=\"chapter\" href=\"é.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"cover\" href=\"coveré.png\" media-type=\"image/png\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"),
        ("OPS/x.xhtml", "<html><body><h1>Opening</h1><p>Preserved text.</p></body></html>"),
        ("OPS/coverx.png", "cover fixture"),
    ] {
        writer.start_file(name, options).unwrap();
        writer.write_all(content.as_bytes()).unwrap();
    }
    let mut archive = writer.finish().unwrap().into_inner();
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
