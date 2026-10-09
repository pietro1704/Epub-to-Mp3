#![cfg(not(target_arch = "wasm32"))]

use converter_core::audio::{embed_cover, probe_duration, probe_sample_rate, validate_audio};
use id3::{frame::PictureType, Tag, TagLike, Version};
use std::{fs, path::Path, process::Command};

// Generated once with ffmpeg: 440 Hz sine, 0.25 s, mono, 24 kHz, 48 kbps,
// libmp3lame, -map_metadata -1 -write_xing 0 -id3v2_version 0.
const MP3: &[u8] = include_bytes!("../../../tests/fixtures/audio/mono-24000-48k.mp3");
// Generated once with ffmpeg: 440 Hz sine, 1 s, mono, 24 kHz, libmp3lame,
// -map_metadata -1 -id3v2_version 0; CBR: -b:a 48k -write_xing 1 (Info),
// VBR: -q:a 4 -write_xing 0. Runtime tests never invoke ffmpeg.
const MP3_INFO: &[u8] = include_bytes!("../../../tests/fixtures/audio/mono-24000-48k-info.mp3");
const MP3_VBR: &[u8] = include_bytes!("../../../tests/fixtures/audio/mono-24000-vbr-no-xing.mp3");
const PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0,
    0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 100, 248, 15, 0, 1, 5, 1, 1,
    39, 24, 227, 102, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];
const GUARD: &str = "CONVERTER_CORE_EMBEDDED_AUDIO_CHILD_20261007";
const COMPLETED: &str = "embedded audio child assertions completed";

fn isolated(child: &str) {
    let output = Command::new(std::env::current_exe().expect("current test executable"))
        .args(["--exact", child, "--nocapture", "--test-threads=1"])
        .env("PATH", "/no-tools")
        .env("FFMPEG", "/no-tools/ffmpeg")
        .env("FFPROBE", "/no-tools/ffprobe")
        .env("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1")
        .env(GUARD, child)
        .output()
        .expect("spawn isolated audio test");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{child}: {}\n{stdout}\n{stderr}",
        output.status
    );
    assert!(
        stdout.contains(COMPLETED),
        "child did not execute assertions: {stdout}"
    );
}

fn child_enabled(name: &str) -> bool {
    if std::env::var(GUARD).as_deref() != Ok(name) {
        return false;
    }
    for (key, expected) in [
        ("PATH", "/no-tools"),
        ("FFMPEG", "/no-tools/ffmpeg"),
        ("FFPROBE", "/no-tools/ffprobe"),
        ("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1"),
    ] {
        assert_eq!(std::env::var(key).unwrap(), expected);
    }
    true
}

fn wav() -> Vec<u8> {
    let pcm: Vec<u8> = (0..6_000i16)
        .flat_map(|sample| ((sample % 100 - 50) * 100).to_le_bytes())
        .collect();
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes()); // PCM
    bytes.extend_from_slice(&1u16.to_le_bytes()); // Mono
    bytes.extend_from_slice(&24_000u32.to_le_bytes());
    bytes.extend_from_slice(&48_000u32.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&pcm);
    bytes
}

// Remove only the ID3v2 envelope; compare the actual MPEG bytes, not decoded PCM.
fn mpeg_payload(bytes: &[u8]) -> &[u8] {
    if !bytes.starts_with(b"ID3") {
        return bytes;
    }
    assert!(bytes.len() >= 10);
    let size = bytes[6..10].iter().fold(0usize, |size, byte| {
        assert_eq!(byte & 0x80, 0, "invalid synchsafe ID3 size");
        (size << 7) | usize::from(*byte)
    });
    let footer = if bytes[3] == 4 && bytes[5] & 0x10 != 0 {
        10
    } else {
        0
    };
    &bytes[10 + size + footer..]
}

#[test]
fn probes_and_validation_work_without_external_tools() {
    isolated("child_probes_and_validation");
}

#[test]
fn child_probes_and_validation() {
    if !child_enabled("child_probes_and_validation") {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    for (name, bytes, tolerance) in [
        ("chapter.mp3", MP3.to_vec(), 0.08),
        ("chapter.wav", wav(), 0.000_001),
        ("wave-content.mp3", wav(), 0.000_001),
    ] {
        let path = directory.path().join(name);
        fs::write(&path, bytes).unwrap();
        assert_eq!(probe_sample_rate(&path).unwrap(), 24_000);
        let duration = probe_duration(&path).unwrap();
        assert!(
            duration.is_finite() && (duration - 0.25).abs() < tolerance,
            "unexpected {name} duration: {duration}"
        );
        assert!((validate_audio(&path, 100).unwrap() - duration).abs() < 1e-9);
        let length = fs::metadata(&path).unwrap().len();
        assert!(validate_audio(&path, length + 1).is_err());
    }
    assert!(
        MP3_INFO
            .windows(4)
            .any(|bytes| bytes == b"Info" || bytes == b"Xing"),
        "fixture must carry a first-segment MPEG frame count"
    );
    assert!(
        !MP3_VBR
            .windows(4)
            .any(|bytes| bytes == b"Info" || bytes == b"Xing"),
        "VBR fixture must exercise duration estimation without Xing/Info"
    );
    for (name, bytes) in [("info", MP3_INFO), ("vbr-no-xing", MP3_VBR)] {
        let single = directory.path().join(format!("{name}-single.mp3"));
        fs::write(&single, bytes).unwrap();
        let duration = probe_duration(&single).unwrap();
        assert!(
            duration.is_finite() && (duration - 1.0).abs() < 0.15,
            "unexpected {name} single duration: {duration}"
        );
        assert_eq!(probe_sample_rate(&single).unwrap(), 24_000);
        assert!((validate_audio(&single, 100).unwrap() - duration).abs() < 1e-9);

        let mut joined = Vec::new();
        for segment in 0..3 {
            let mut tag = Tag::new();
            tag.set_title(format!("Synthetic segment {segment}"));
            tag.write_to(&mut joined, Version::Id3v24).unwrap();
            joined.extend_from_slice(bytes);
        }
        let path = directory.path().join(format!("{name}-joined.mp3"));
        fs::write(&path, joined).unwrap();
        let joined_duration = probe_duration(&path).unwrap();
        // Allow one MPEG-2 Layer III frame per segment for metadata handling.
        assert!(
            joined_duration.is_finite() && (joined_duration - 3.0 * duration).abs() < 0.08,
            "{name} joined duration {joined_duration} must sum three segments of {duration}"
        );
        assert_eq!(probe_sample_rate(&path).unwrap(), 24_000);
        assert!((validate_audio(&path, 100).unwrap() - joined_duration).abs() < 1e-9);
    }
    println!("{COMPLETED}");
}

#[test]
fn invalid_audio_is_rejected_without_external_tools() {
    isolated("child_invalid_audio");
}

#[test]
fn explicit_mpeg_counts_reject_whole_frame_truncation_without_external_tools() {
    isolated("child_explicit_mpeg_counts");
}

#[test]
fn child_explicit_mpeg_counts() {
    if !child_enabled("child_explicit_mpeg_counts") {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    // The fixture's final 48 kbps / 24 kHz MPEG-2 frame is exactly 144 bytes.
    assert_eq!(&MP3_INFO[MP3_INFO.len() - 144..][..2], &[0xff, 0xf3]);
    for marker in [b"Info", b"Xing"] {
        for protected in [false, true] {
            let mut bytes = MP3_INFO.to_vec();
            let tag = bytes.windows(4).position(|bytes| bytes == b"Info").unwrap();
            bytes[tag..tag + 4].copy_from_slice(marker);
            if protected {
                // Exercise the protected metadata envelope, not CRC checksum verification.
                // LAME places Info/Xing at the same offset despite these CRC bytes.
                bytes[1] &= !1;
                bytes[4..6].copy_from_slice(&[0xa5, 0x5a]);
            }
            let path = directory.path().join("complete.mp3");
            fs::write(&path, &bytes).unwrap();
            assert!((probe_duration(&path).unwrap() - 1.0).abs() < 0.15);
            bytes.truncate(bytes.len() - 144);
            for prefix in [&[][..], MP3_INFO] {
                let path = directory.path().join("truncated.mp3");
                fs::write(&path, [prefix, bytes.as_slice()].concat()).unwrap();
                assert!(probe_duration(&path).is_err(), "accepted missing frame");
                assert!(probe_sample_rate(&path).is_err(), "accepted missing frame");
                assert!(
                    validate_audio(&path, 100).is_err(),
                    "accepted missing frame"
                );
            }
        }
    }
    println!("{COMPLETED}");
}

#[test]
fn binary_midstream_id3_is_not_decoded_as_audio_without_external_tools() {
    isolated("child_binary_midstream_id3");
}

#[test]
fn child_binary_midstream_id3() {
    if !child_enabled("child_binary_midstream_id3") {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let single = directory.path().join("single.mp3");
    fs::write(&single, MP3).unwrap();
    let duration = probe_duration(&single).unwrap();
    let cover = directory.path().join("cover.png");
    fs::write(&cover, PNG).unwrap();
    for payload in [MP3, &[0xff, 0xf3, 0x84, 0xc0][..]] {
        let mut tag = Tag::new();
        tag.add_frame(id3::frame::Private {
            owner_identifier: "embedded-audio-regression".into(),
            private_data: payload.to_vec(),
        });
        let mut bytes = MP3.to_vec();
        tag.write_to(&mut bytes, Version::Id3v24).unwrap();
        bytes.extend_from_slice(MP3);
        let path = directory.path().join("binary-tag.mp3");
        fs::write(&path, &bytes).unwrap();
        assert!((probe_duration(&path).unwrap() - 2.0 * duration).abs() < 1e-9);
        assert_eq!(probe_sample_rate(&path).unwrap(), 24_000);
        assert!((validate_audio(&path, 100).unwrap() - 2.0 * duration).abs() < 1e-9);
        embed_cover(&path, &cover).unwrap();
        assert_eq!(mpeg_payload(&fs::read(&path).unwrap()), bytes.as_slice());
        assert!((probe_duration(&path).unwrap() - 2.0 * duration).abs() < 1e-9);
    }
    println!("{COMPLETED}");
}

#[test]
fn child_invalid_audio() {
    if !child_enabled("child_invalid_audio") {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let wave = wav();
    for (name, bytes) in [
        ("empty.mp3", &[][..]),
        ("garbage.mp3", &b"not audio at all"[..]),
        ("truncated.mp3", &MP3[..8]),
        ("tail-truncated.mp3", &MP3[..MP3.len() - 10]),
        ("truncated.wav", &wave[..44]),
        ("data-truncated.wav", &wave[..wave.len() - 10]),
    ] {
        let path = directory.path().join(name);
        fs::write(&path, bytes).unwrap();
        assert!(probe_duration(&path).is_err(), "duration accepted {name}");
        assert!(
            probe_sample_rate(&path).is_err(),
            "sample rate accepted {name}"
        );
        assert!(
            validate_audio(&path, 0).is_err(),
            "validation accepted {name}"
        );
    }
    println!("{COMPLETED}");
}

#[test]
fn covers_preserve_audio_and_metadata_without_external_tools() {
    isolated("child_covers_preserve_audio_and_metadata");
}

fn assert_cover(path: &Path) {
    let tag = Tag::read_from_path(path).unwrap();
    assert_eq!(tag.title(), Some("Synthetic chapter"));
    assert_eq!(tag.artist(), Some("Synthetic narrator"));
    let pictures: Vec<_> = tag.pictures().collect();
    assert_eq!(
        pictures.len(),
        1,
        "cover writes must not duplicate APIC frames"
    );
    assert_eq!(pictures[0].picture_type, PictureType::CoverFront);
    assert_eq!(pictures[0].mime_type, "image/png");
    assert_eq!(pictures[0].data.as_slice(), PNG);
}

#[test]
fn child_covers_preserve_audio_and_metadata() {
    if !child_enabled("child_covers_preserve_audio_and_metadata") {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("chapter.mp3");
    let cover = directory.path().join("cover.png");
    fs::write(&path, MP3).unwrap();
    fs::write(&cover, PNG).unwrap();
    let mut tag = Tag::new();
    tag.set_title("Synthetic chapter");
    tag.set_artist("Synthetic narrator");
    tag.write_to_path(&path, Version::Id3v24).unwrap();
    let original = fs::read(&path).unwrap();
    let duration = probe_duration(&path).unwrap();
    for _ in 0..2 {
        embed_cover(&path, &cover).unwrap();
        assert_cover(&path);
        let current = fs::read(&path).unwrap();
        assert_eq!(mpeg_payload(&current), mpeg_payload(&original));
        assert!((probe_duration(&path).unwrap() - duration).abs() < 1e-9);
        assert!((validate_audio(&path, 100).unwrap() - duration).abs() < 1e-9);
        assert_eq!(probe_sample_rate(&path).unwrap(), 24_000);
    }
    for bytes in [&[][..], &b"not an image"[..], &PNG[..16]] {
        fs::write(&cover, bytes).unwrap();
        let before = fs::read(&path).unwrap();
        assert!(
            embed_cover(&path, &cover).is_err(),
            "invalid cover accepted"
        );
        assert_eq!(fs::read(&path).unwrap(), before, "bad cover changed audio");
    }
    println!("{COMPLETED}");
}
