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
    // ZIP headers store filename bytes outside the payload CRC. 0x82 is CP437 é.
    for (signature, flags_offset, name_offset) in [
        (b"PK\x03\x04", 6, 30),
        (b"PK\x01\x02", 8, 46),
    ] {
        let start = archive.windows(4).position(|bytes| bytes == signature).unwrap();
        let flags = u16::from_le_bytes([
            archive[start + flags_offset],
            archive[start + flags_offset + 1],
        ]) & !0x0800;
        archive[start + flags_offset..start + flags_offset + 2]
            .copy_from_slice(&flags.to_le_bytes());
        assert_eq!(&archive[start + name_offset..start + name_offset + 5], b"x.txt");
        archive[start + name_offset] = 0x82;
    }
    assert_eq!(list_members(Cursor::new(&archive)).unwrap()[0].name, "é.txt");
    let directory = tempfile::tempdir().unwrap();
    let output = directory.path().join("chapter.txt");
    extract_member(Cursor::new(&archive), "é.txt", &output).unwrap();
    assert_eq!(std::fs::read(output).unwrap(), b"chapter content");
}
