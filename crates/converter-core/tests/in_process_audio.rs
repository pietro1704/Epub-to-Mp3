#![cfg(not(target_arch = "wasm32"))]

use converter_core::audio::{embed_cover, probe_duration, probe_sample_rate, validate_audio};
use id3::{
    frame::{Picture, PictureType},
    Tag, TagLike, Version,
};
use std::{fs, io::Cursor, path::Path, process::Command};

// Independently generated: 730 Hz, stereo, 44.1 kHz, 64 kbps, 0.18 seconds,
// no ID3 or Xing envelope. A non-audio extension exercises content sniffing.
const MPEG: &[u8] = include_bytes!("fixtures/frame-stream-stereo.fixture");

fn wave() -> Vec<u8> {
    let pcm = vec![0u8; 320];
    let mut result = Vec::new();
    result.extend_from_slice(b"RIFF");
    result.extend_from_slice(&(36u32 + pcm.len() as u32).to_le_bytes());
    result.extend_from_slice(b"WAVEfmt ");
    result.extend_from_slice(&16u32.to_le_bytes());
    result.extend_from_slice(&1u16.to_le_bytes());
    result.extend_from_slice(&1u16.to_le_bytes());
    result.extend_from_slice(&8000u32.to_le_bytes());
    result.extend_from_slice(&16000u32.to_le_bytes());
    result.extend_from_slice(&2u16.to_le_bytes());
    result.extend_from_slice(&16u16.to_le_bytes());
    result.extend_from_slice(b"data");
    result.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    result.extend(pcm);
    result
}

fn compressed_payload(bytes: &[u8]) -> &[u8] {
    if bytes.starts_with(b"ID3") {
        let mut tag_size = 0usize;
        for byte in &bytes[6..10] {
            tag_size = tag_size * 128 + usize::from(*byte);
        }
        &bytes[10 + tag_size..]
    } else {
        bytes
    }
}

fn image_bytes(format: image::ImageFormat) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(3, 2, image::Rgb([40, 90, 150])))
        .write_to(&mut bytes, format)
        .unwrap();
    bytes.into_inner()
}

fn assert_native_audio(root: &Path) {
    let mp3 = root.join("chapter.bin");
    fs::write(&mp3, MPEG).unwrap();
    assert_eq!(probe_sample_rate(&mp3).unwrap(), 44100);
    let duration = validate_audio(&mp3, 100).unwrap();
    assert!(
        (0.15..0.30).contains(&duration),
        "unexpected MPEG duration {duration}"
    );
    let wav = root.join("wave-disguised-as.mp3");
    fs::write(&wav, wave()).unwrap();
    assert_eq!(probe_sample_rate(&wav).unwrap(), 8000);
    assert!((probe_duration(&wav).unwrap() - 0.02).abs() < 1e-8);
    for (name, bytes) in [
        ("incomplete-mpeg.bin", MPEG[..MPEG.len() - 5].to_vec()),
        ("incomplete-wave.bin", wave()[..wave().len() - 1].to_vec()),
        ("no-frames.bin", b"ID3\x04\0\0\0\0\0\0".to_vec()),
        ("garbage.bin", b"invalid audio".to_vec()),
    ] {
        let path = root.join(name);
        fs::write(&path, bytes).unwrap();
        assert!(validate_audio(path, 0).is_err(), "accepted {name}");
    }
    let mut tag = Tag::new();
    tag.set_title("Preserved chapter");
    tag.set_artist("Preserved voice");
    tag.add_frame(Picture {
        mime_type: "image/png".into(),
        picture_type: PictureType::CoverBack,
        description: "existing back".into(),
        data: image_bytes(image::ImageFormat::Png),
    });
    tag.write_to_path(&mp3, Version::Id3v24).unwrap();
    let original = fs::read(&mp3).unwrap();
    for (format, mime) in [
        (image::ImageFormat::Png, "image/png"),
        (image::ImageFormat::Jpeg, "image/jpeg"),
        (image::ImageFormat::WebP, "image/webp"),
    ] {
        let cover = root.join("cover.bin");
        let bytes = image_bytes(format);
        fs::write(&cover, &bytes).unwrap();
        for _ in 0..2 {
            embed_cover(&mp3, &cover).unwrap();
            let current = fs::read(&mp3).unwrap();
            assert_eq!(compressed_payload(&current), compressed_payload(&original));
            let tag = Tag::read_from_path(&mp3).unwrap();
            assert_eq!(tag.title(), Some("Preserved chapter"));
            assert_eq!(tag.artist(), Some("Preserved voice"));
            let front: Vec<_> = tag
                .pictures()
                .filter(|p| p.picture_type == PictureType::CoverFront)
                .collect();
            assert_eq!(front.len(), 1);
            assert_eq!(front[0].mime_type, mime);
            assert_eq!(front[0].data, bytes);
            assert_eq!(
                tag.pictures()
                    .filter(|p| p.picture_type == PictureType::CoverBack)
                    .count(),
                1
            );
            assert!((probe_duration(&mp3).unwrap() - duration).abs() < 1e-8);
        }
    }
    let invalid_cover = root.join("bad-cover.bin");
    let complete = image_bytes(image::ImageFormat::Png);
    for bytes in [
        b"not image".to_vec(),
        complete[..complete.len() - 8].to_vec(),
    ] {
        fs::write(&invalid_cover, bytes).unwrap();
        let before = fs::read(&mp3).unwrap();
        assert!(embed_cover(&mp3, &invalid_cover).is_err());
        assert_eq!(fs::read(&mp3).unwrap(), before);
    }
    let jpeg = image_bytes(image::ImageFormat::Jpeg);
    let thumbnail_marker = b"thumbnail\xff\xd9";
    let mut misleading_jpeg = vec![0xff, 0xd8, 0xff, 0xe1];
    misleading_jpeg.extend_from_slice(&((thumbnail_marker.len() + 2) as u16).to_be_bytes());
    misleading_jpeg.extend_from_slice(thumbnail_marker);
    misleading_jpeg.extend_from_slice(&jpeg[2..jpeg.len() - 2]);
    fs::write(&invalid_cover, misleading_jpeg).unwrap();
    let before = fs::read(&mp3).unwrap();
    assert!(
        embed_cover(&mp3, &invalid_cover).is_err(),
        "thumbnail EOI cannot hide a truncated main JPEG"
    );
    assert_eq!(fs::read(&mp3).unwrap(), before);
    let large_cover = root.join("large-cover.png");
    let cover_file = fs::File::create(&large_cover).unwrap();
    cover_file.set_len(16 * 1024 * 1024 + 1).unwrap();
    assert!(embed_cover(&mp3, &large_cover)
        .unwrap_err()
        .to_string()
        .contains("compressed image budget"));
    assert_eq!(fs::read(&mp3).unwrap(), before);
    let mut dimension_bomb = image_bytes(image::ImageFormat::Png);
    dimension_bomb[16..20].copy_from_slice(&9000u32.to_be_bytes());
    let mut crc = !0u32;
    for byte in &dimension_bomb[12..29] {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ if crc & 1 != 0 { 0xedb88320 } else { 0 };
        }
    }
    dimension_bomb[29..33].copy_from_slice(&(!crc).to_be_bytes());
    fs::write(&invalid_cover, dimension_bomb).unwrap();
    let error = embed_cover(&mp3, &invalid_cover)
        .unwrap_err()
        .to_string()
        .to_lowercase();
    assert!(
        error.contains("dimension") || error.contains("limit"),
        "expected bounded decode: {error}"
    );
    assert_eq!(fs::read(&mp3).unwrap(), before);
    let cover = root.join("wave-cover.png");
    fs::write(&cover, image_bytes(image::ImageFormat::Png)).unwrap();
    let original_wave = wave();
    embed_cover(&wav, &cover).unwrap();
    let tagged_wave = fs::read(&wav).unwrap();
    assert!(tagged_wave.starts_with(b"RIFF"));
    assert_eq!(&tagged_wave[44..44 + 320], &original_wave[44..]);
    assert_eq!(
        Tag::read_from_path(&wav)
            .unwrap()
            .pictures()
            .filter(|p| p.picture_type == PictureType::CoverFront)
            .count(),
        1
    );
    assert!((validate_audio(&wav, 100).unwrap() - 0.02).abs() < 1e-8);
}

#[cfg(not(target_os = "ios"))]
#[test]
fn unsupported_native_wave_codec_preserves_external_capability() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("adpcm.wav");
    fs::write(&path, include_bytes!("fixtures/desktop-adpcm.fixture")).unwrap();
    assert_eq!(probe_sample_rate(&path).unwrap(), 8000);
    assert!(validate_audio(&path, 100).unwrap() > 0.0);
}

#[test]
fn native_audio_decodes_and_tags_with_external_tools_disabled() {
    let root = tempfile::tempdir().unwrap();
    let sentinel = root.path().join("forbidden-tool");
    fs::write(&sentinel, b"#!/bin/sh\nexit 97\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&sentinel, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let result = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "isolated_native_audio_child", "--nocapture"])
        .env("NATIVE_AUDIO_CHILD_ROOT", root.path())
        .env("FFPROBE", &sentinel)
        .env("FFMPEG", &sentinel)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(String::from_utf8_lossy(&result.stdout).contains("native audio assertions executed"));
}

#[test]
fn isolated_native_audio_child() {
    if let Some(root) = std::env::var_os("NATIVE_AUDIO_CHILD_ROOT") {
        assert_native_audio(Path::new(&root));
        println!("native audio assertions executed");
    }
}
