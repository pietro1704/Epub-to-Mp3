//! Typed audio post-processing and archive facade.
mod audio_archive;
mod audio_encoding;
mod audio_process;
mod audio_validation;
mod cover_image_validation;
mod mp3_metadata;
mod mpeg_frame_validation;
mod wave_bounds;

pub use audio_archive::create_archive;
pub use audio_encoding::{add_silence_padding, concatenate, wav_to_mp3, Padding};
pub use audio_process::ProcessSpec;
pub use audio_validation::{probe_duration, probe_sample_rate, validate_audio};
pub use mp3_metadata::{embed_cover, write_metadata, ChapterMetadata};

use std::io;
use thiserror::Error;

#[cfg(test)]
use audio_process::resolve_program_in;
#[cfg(test)]
pub(crate) use audio_validation::collect_rusty_mp3_output;
#[cfg(test)]
use mpeg_frame_validation::{
    mpeg_info_counts, validate_mpeg_bounds, AudioSegmentSource, MpegSegment,
};
#[cfg(test)]
use std::fs::{self, File};
#[cfg(test)]
use std::io::{Read, Seek, SeekFrom};

#[derive(Debug, Error)]
pub enum AudioError {
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("invalid audio configuration: {0}")]
    InvalidConfig(String),
    #[error("{program} failed with status {status}: {stderr}")]
    Process {
        program: String,
        status: String,
        stderr: String,
    },
    #[error("audio validation failed: {0}")]
    Validation(String),
    #[error("archive error: {0}")]
    Archive(#[from] zip::result::ZipError),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finished_rusty_encoder_normalizes_only_metadata_and_rejects_frame_loss() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("native-encoder.mp3");
        for rate in [16_000, 22_050, 24_000, 44_100] {
            for channels in [1, 2] {
                let pcm: Vec<u8> = (0..rate / 8)
                    .flat_map(|index| {
                        let sample = ((index % 100) as i16 - 50) * 100;
                        (0..channels).flat_map(move |_| sample.to_le_bytes())
                    })
                    .collect();
                let prepare = || {
                    let mut encoder = rusty_mp3::Mp3Encoder::new(rusty_mp3::Mp3EncoderConfig {
                        bitrate_kbps: 96,
                        vbr_quality: None,
                    });
                    encoder.push_pcm_s16le(&pcm, channels, rate).unwrap();
                    encoder.finish();
                    encoder
                };
                let mut original = prepare();
                let mut raw = Vec::new();
                let mut last_frame_bytes = 0;
                while let Ok(packet) = original.next_packet() {
                    last_frame_bytes = packet.len();
                    raw.extend_from_slice(&packet);
                }
                let mut finished = prepare();
                let encoded = collect_rusty_mp3_output(&mut finished).unwrap();
                let header =
                    rusty_mp3::header::FrameHeader::parse(raw[..4].try_into().unwrap()).unwrap();
                let field = 4 + usize::from(header.crc_protected) * 2 + header.side_info_len() + 8;
                assert_eq!(&encoded[..field], &raw[..field]);
                assert_eq!(&encoded[field + 4..], &raw[field + 4..]);
                let old_count = u32::from_be_bytes(raw[field..field + 4].try_into().unwrap());
                let new_count = u32::from_be_bytes(encoded[field..field + 4].try_into().unwrap());
                assert_eq!(new_count + 1, old_count);
                fs::write(&path, &encoded).unwrap();
                assert_eq!(
                    validate_mpeg_bounds(&mut File::open(&path).unwrap())
                        .unwrap()
                        .len(),
                    1
                );
                assert!(probe_duration(&path).unwrap() > 0.0);
                assert_eq!(probe_sample_rate(&path).unwrap(), rate);
                fs::write(&path, &encoded[..encoded.len() - last_frame_bytes]).unwrap();
                assert!(validate_mpeg_bounds(&mut File::open(&path).unwrap()).is_err());
                assert!(probe_duration(&path).is_err());
            }
        }
    }

    #[test]
    fn rusty_encoder_collection_rejects_unfinished_or_empty_streams() {
        let mut encoder = rusty_mp3::Mp3Encoder::new(rusty_mp3::Mp3EncoderConfig {
            bitrate_kbps: 96,
            vbr_quality: None,
        });
        assert!(collect_rusty_mp3_output(&mut encoder).is_err());
        encoder.finish();
        assert!(collect_rusty_mp3_output(&mut encoder).is_err());
    }

    #[test]
    fn bounded_audio_source_preserves_logical_identity_and_hides_adjacent_bytes() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("segments.bin");
        fs::write(&path, b"beforePAYLOADafter").unwrap();
        let mut source = AudioSegmentSource::new(
            File::open(&path).unwrap(),
            MpegSegment {
                start: 6,
                length: 7,
            },
        )
        .unwrap();
        let mut payload = Vec::new();
        source.read_to_end(&mut payload).unwrap();
        assert_eq!(payload, b"PAYLOAD");
        assert_eq!(source.seek(SeekFrom::End(-3)).unwrap(), 4);
        let mut tail = [0; 3];
        source.read_exact(&mut tail).unwrap();
        assert_eq!(&tail, b"OAD");
        assert!(source.seek(SeekFrom::Start(8)).is_err());
        assert!(source.seek(SeekFrom::End(-8)).is_err());
        assert_eq!(source.seek(SeekFrom::Start(0)).unwrap(), 0);
        let mut first = [0; 1];
        source.read_exact(&mut first).unwrap();
        assert_eq!(&first, b"P");
        assert!(AudioSegmentSource::new(
            File::open(&path).unwrap(),
            MpegSegment {
                start: 6,
                length: 99
            },
        )
        .is_err());
        assert!(AudioSegmentSource::new(
            File::open(&path).unwrap(),
            MpegSegment {
                start: u64::MAX,
                length: 1
            },
        )
        .is_err());
    }

    #[cfg(unix)]
    #[test]
    fn bounded_segments_retain_validated_file_identity_after_path_replacement() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("audio.bin");
        fs::write(&path, b"FIRSTSECOND").unwrap();
        let validated = File::open(&path).unwrap();
        let replacement = root.path().join("replacement.bin");
        fs::write(&replacement, b"OTHERVALUES").unwrap();
        fs::rename(&replacement, &path).unwrap();
        for (segment, expected) in [
            (
                MpegSegment {
                    start: 0,
                    length: 5,
                },
                &b"FIRST"[..],
            ),
            (
                MpegSegment {
                    start: 5,
                    length: 6,
                },
                &b"SECOND"[..],
            ),
        ] {
            let mut source =
                AudioSegmentSource::new(validated.try_clone().unwrap(), segment).unwrap();
            let mut bytes = Vec::new();
            source.read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes, expected);
        }
        assert_eq!(fs::read(path).unwrap(), b"OTHERVALUES");
    }

    #[test]
    fn mpeg_segments_exclude_id3_payloads_and_split_direct_info_concatenation() {
        const AUDIO: &[u8] =
            include_bytes!("../../../tests/fixtures/audio/mono-24000-48k-info.mp3");
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("segments.mp3");
        fs::write(&path, [AUDIO, AUDIO].concat()).unwrap();
        let segments = validate_mpeg_bounds(&mut File::open(&path).unwrap()).unwrap();
        assert_eq!(
            segments,
            vec![
                MpegSegment {
                    start: 0,
                    length: AUDIO.len() as u64
                },
                MpegSegment {
                    start: AUDIO.len() as u64,
                    length: AUDIO.len() as u64
                },
            ]
        );
        // A complete MPEG file inside private ID3 data must never become audio.
        let mut tag = vec![b'I', b'D', b'3', 4, 0, 0];
        let size = AUDIO.len();
        tag.extend_from_slice(&[
            ((size >> 21) & 127) as u8,
            ((size >> 14) & 127) as u8,
            ((size >> 7) & 127) as u8,
            (size & 127) as u8,
        ]);
        tag.extend_from_slice(AUDIO);
        fs::write(&path, [AUDIO, tag.as_slice(), AUDIO].concat()).unwrap();
        let segments = validate_mpeg_bounds(&mut File::open(&path).unwrap()).unwrap();
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].length, AUDIO.len() as u64);
        assert_eq!(segments[1].start, (AUDIO.len() + tag.len()) as u64);
        assert_eq!(segments[1].length, AUDIO.len() as u64);
        // An ID3 envelope claiming bytes beyond EOF is not a partial success.
        fs::write(&path, [AUDIO, &tag[..tag.len() - 1]].concat()).unwrap();
        assert!(validate_mpeg_bounds(&mut File::open(path).unwrap()).is_err());
    }

    #[test]
    fn mpeg_explicit_counts_reject_inconsistent_frames_bytes_and_short_metadata() {
        const AUDIO: &[u8] =
            include_bytes!("../../../tests/fixtures/audio/mono-24000-48k-info.mp3");
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("counts.mp3");
        let marker = AUDIO.windows(4).position(|bytes| bytes == b"Info").unwrap();
        for field in [marker + 8, marker + 12] {
            let mut bytes = AUDIO.to_vec();
            let declared = u32::from_be_bytes(bytes[field..field + 4].try_into().unwrap());
            bytes[field..field + 4].copy_from_slice(&(declared + 1).to_be_bytes());
            fs::write(&path, bytes).unwrap();
            assert!(validate_mpeg_bounds(&mut File::open(&path).unwrap()).is_err());
        }
        fs::write(&path, AUDIO).unwrap();
        let bits = u32::from_be_bytes(AUDIO[..4].try_into().unwrap());
        // The flags declare frame and byte counts, but this extent ends before them.
        assert!(
            mpeg_info_counts(&mut File::open(path).unwrap(), 0, (marker + 8) as u64, bits).is_err()
        );
    }

    #[test]
    fn concurrent_archives_publish_a_complete_zip_without_staging_collisions() {
        let root = tempfile::tempdir().unwrap();
        let output = root.path().join("book.zip");
        let sources: Vec<_> = (0..8)
            .map(|index| {
                let path = root.path().join(format!("chapter-{index}.mp3"));
                fs::write(&path, vec![index as u8; 1024 * 1024]).unwrap();
                (path, format!("chapter-{index}.mp3"))
            })
            .collect();
        let barrier = std::sync::Barrier::new(sources.len());
        std::thread::scope(|scope| {
            let handles: Vec<_> = sources
                .iter()
                .map(|source| {
                    let output = &output;
                    let barrier = &barrier;
                    scope.spawn(move || {
                        barrier.wait();
                        create_archive(output, std::slice::from_ref(source))
                    })
                })
                .collect();
            for handle in handles {
                handle.join().unwrap().unwrap();
            }
        });

        let mut archive = zip::ZipArchive::new(File::open(output).unwrap()).unwrap();
        assert_eq!(archive.len(), 1);
        let mut chapter = archive.by_index(0).unwrap();
        let chapter_name = chapter.name().unwrap();
        let index = sources
            .iter()
            .position(|(_, name)| name == chapter_name.as_ref())
            .unwrap();
        let mut bytes = Vec::new();
        chapter.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, vec![index as u8; 1024 * 1024]);
        assert_eq!(
            fs::read_dir(root.path()).unwrap().count(),
            sources.len() + 1
        );
    }

    #[test]
    fn failed_archive_preserves_previous_zip_and_removes_temporary_files() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("chapter.mp3");
        let output = root.path().join("book.zip");
        fs::write(&source, b"complete chapter").unwrap();
        create_archive(&output, &[(source, "chapter.mp3".into())]).unwrap();
        let previous = fs::read(&output).unwrap();
        assert!(create_archive(
            &output,
            &[(root.path().join("missing.mp3"), "missing.mp3".into())]
        )
        .is_err());
        assert_eq!(fs::read(output).unwrap(), previous);
        assert_eq!(
            fs::read_dir(root.path()).unwrap().count(),
            2,
            "failed archive creation must not leave temporary files"
        );
    }

    #[test]
    fn zero_padding_is_noop() {
        assert_eq!(
            Padding {
                intro_ms: 0,
                outro_ms: 0,
                ..Default::default()
            },
            Padding {
                intro_ms: 0,
                outro_ms: 0,
                sample_rate: 16_000,
                channels: 1
            }
        );
    }
    #[test]
    fn process_is_typed() {
        assert_eq!(
            ProcessSpec::new("ffmpeg").arg("-y").args(["-i", "input"]),
            ProcessSpec {
                program: "ffmpeg".into(),
                args: vec!["-y".into(), "-i".into(), "input".into()]
            }
        );
    }

    #[test]
    fn resolves_probe_from_package_manager_paths_when_app_path_is_restricted() {
        let path_dir = tempfile::tempdir().unwrap();
        let fallback_dir = tempfile::tempdir().unwrap();
        let expected = fallback_dir.path().join("ffprobe");
        fs::write(&expected, b"test executable placeholder").unwrap();

        let resolved = resolve_program_in(
            "ffprobe",
            None,
            [path_dir.path().to_path_buf()],
            [fallback_dir.path().to_path_buf()],
        );

        assert_eq!(resolved, expected);
    }
}
