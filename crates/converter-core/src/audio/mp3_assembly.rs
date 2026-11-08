//! Finalize independently encoded MPEG segments as one seekable stream.
use super::{
    audio_validation::invalid_audio,
    mpeg_frame_validation::{mpeg_info_counts, validate_mpeg_bounds},
    AudioError,
};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
};

/// A bounded header check avoids rescanning every healthy chapter on queue
/// mounting. This is a repair decision, not a replacement for audio validation.
pub fn mp3_needs_finalization(path: &Path) -> Result<bool, AudioError> {
    let mut file = File::open(path)?;
    let mut start = 0;
    let mut end = file.metadata()?.len();
    let mut bytes = [0; 10];
    if file.read(&mut bytes)? < 10 {
        return Ok(false);
    }
    if &bytes[..3] == b"ID3" {
        if bytes[6..].iter().any(|b| b & 0x80 != 0) {
            return Err(invalid_audio("Invalid ID3 extent"));
        }
        start = 10
            + bytes[6..]
                .iter()
                .fold(0u64, |size, byte| size * 128 + u64::from(*byte));
        if bytes[3] == 4 && bytes[5] & 0x10 != 0 {
            start += 10;
        }
    } else if bytes[0] != 0xff {
        return Ok(false);
    }
    if end >= 128 {
        file.seek(SeekFrom::Start(end - 128))?;
        let mut tag = [0; 3];
        file.read_exact(&mut tag)?;
        if &tag == b"TAG" {
            end -= 128;
        }
    }
    if end >= 32 {
        file.seek(SeekFrom::Start(end - 32))?;
        let mut footer = [0; 32];
        file.read_exact(&mut footer)?;
        if &footer[..8] == b"APETAGEX" {
            let size = u64::from(u32::from_le_bytes(footer[12..16].try_into().unwrap()));
            if size < 32 || size > end {
                return Err(invalid_audio("Invalid APE extent"));
            }
            end -= size;
            if end >= 32 {
                file.seek(SeekFrom::Start(end - 32))?;
                let mut header = [0; 8];
                file.read_exact(&mut header)?;
                if &header == b"APETAGEX" {
                    end -= 32;
                }
            }
        }
    }
    if end < start + 4 {
        return Err(invalid_audio("Truncated MPEG audio"));
    }
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = [0; 4];
    file.read_exact(&mut bytes)?;
    let header =
        rusty_mp3::header::FrameHeader::parse(bytes).map_err(|e| invalid_audio(e.to_string()))?;
    let counts = mpeg_info_counts(
        &mut file,
        start,
        header.frame_size() as u64,
        u32::from_be_bytes(bytes),
    )?;
    Ok(!counts.is_some_and(|counts| counts.declares_extent(end - start)))
}

/// Preserve audio frame payloads and outer tags, replacing per-segment duration
/// headers with a single aggregate Xing header. Publication is atomic; invalid
/// input never replaces the retained file. No external encoder is required.
pub fn finalize_mp3(path: &Path) -> Result<bool, AudioError> {
    if !mp3_needs_finalization(path)? {
        return Ok(false);
    }
    let mut input = File::open(path)?;
    let mut signature = [0; 3];
    if input.read(&mut signature)? < 3 || (signature != *b"ID3" && signature[0] != 0xff) {
        return Ok(false); // Other supported audio formats are not MPEG assembly.
    }
    let segments = validate_mpeg_bounds(&mut input)?;
    if segments.len() == 1 {
        return Ok(false);
    }
    let mut frames = Vec::new();
    let mut format = None;
    let mut prototype = None;
    for segment in &segments {
        let mut position = segment.start;
        while position < segment.start + segment.length {
            input.seek(SeekFrom::Start(position))?;
            let mut bytes = [0; 4];
            input.read_exact(&mut bytes)?;
            let header = rusty_mp3::header::FrameHeader::parse(bytes)
                .map_err(|e| invalid_audio(format!("Invalid MPEG frame: {e}")))?;
            let bits = u32::from_be_bytes(bytes);
            let identity = bits & 0x001e0cc0; // Version, layer, rate and channel mode.
            if format.is_some_and(|value| value != identity) {
                return Err(invalid_audio(
                    "Cannot assemble MPEG segments with different formats",
                ));
            }
            format = Some(identity);
            let length = header.frame_size();
            let tag = 4 + header.side_info_len();
            let mut marker = [0; 4];
            input.seek(SeekFrom::Start(position + tag as u64))?;
            input.read_exact(&mut marker)?;
            let mut metadata = marker == *b"Info" || marker == *b"Xing";
            if !metadata && header.crc_protected {
                input.seek(SeekFrom::Start(position + tag as u64 + 2))?;
                input.read_exact(&mut marker)?;
                metadata = marker == *b"Info" || marker == *b"Xing";
            }
            if prototype.is_none() {
                // A metadata-only frame has no audio CRC or reservoir payload.
                let mut frame = vec![0; length];
                frame[..4].copy_from_slice(&(bits | (1 << 16)).to_be_bytes());
                if tag + 116 > length {
                    return Err(invalid_audio("MPEG metadata frame too short"));
                }
                prototype = Some((frame, tag));
            }
            if !metadata {
                frames.push((position, length));
            }
            position += length as u64;
        }
    }
    let (mut metadata, tag) = prototype.ok_or_else(|| invalid_audio("No MPEG frames"))?;
    let count = u32::try_from(frames.len()).map_err(|_| invalid_audio("Too many MPEG frames"))?;
    let bytes = frames
        .iter()
        .try_fold(metadata.len() as u64, |sum, (_, len)| {
            sum.checked_add(*len as u64)
        })
        .and_then(|sum| u32::try_from(sum).ok())
        .ok_or_else(|| invalid_audio("MPEG stream exceeds Xing size limit"))?;
    metadata[tag..tag + 4].copy_from_slice(b"Xing");
    metadata[tag + 4..tag + 8].copy_from_slice(&7u32.to_be_bytes());
    metadata[tag + 8..tag + 12].copy_from_slice(&count.to_be_bytes());
    metadata[tag + 12..tag + 16].copy_from_slice(&bytes.to_be_bytes());
    let mut offset = metadata.len() as u64;
    let mut bucket = 0;
    for (index, (_, length)) in frames.iter().enumerate() {
        while bucket < 100 && index >= frames.len() * bucket / 100 {
            metadata[tag + 16 + bucket] = (offset * 256 / u64::from(bytes)).min(255) as u8;
            bucket += 1;
        }
        offset += *length as u64;
    }
    let mut pending = tempfile::NamedTempFile::new_in(path.parent().unwrap_or(Path::new(".")))?;
    input.seek(SeekFrom::Start(0))?;
    std::io::copy(&mut (&mut input).take(segments[0].start), &mut pending)?;
    pending.write_all(&metadata)?;
    for (position, length) in frames {
        input.seek(SeekFrom::Start(position))?;
        std::io::copy(&mut (&mut input).take(length as u64), &mut pending)?;
    }
    let last = segments.last().unwrap();
    input.seek(SeekFrom::Start(last.start + last.length))?;
    std::io::copy(&mut input, &mut pending)?;
    pending.as_file_mut().sync_all()?;
    validate_mpeg_bounds(pending.as_file_mut())?;
    pending
        .as_file()
        .set_permissions(input.metadata()?.permissions())?;
    // Windows cannot replace the destination while this reader holds it open.
    drop(input);
    pending.persist(path).map_err(|error| error.error)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    const AUDIO: &[u8] = include_bytes!("../../../../tests/fixtures/audio/mono-24000-48k-info.mp3");

    #[test]
    fn aggregate_headers_cover_every_audio_frame_without_reencoding() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.mp3");
        std::fs::write(&path, [AUDIO, AUDIO, AUDIO].concat()).unwrap();
        assert!(finalize_mp3(&path).unwrap());
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(
            validate_mpeg_bounds(&mut File::open(&path).unwrap())
                .unwrap()
                .len(),
            1
        );
        let first = rusty_mp3::header::FrameHeader::parse(AUDIO[..4].try_into().unwrap()).unwrap();
        assert_eq!(
            &bytes[first.frame_size()..],
            AUDIO[first.frame_size()..].repeat(3)
        );
        assert!(!finalize_mp3(&path).unwrap());
        // Optional real Apple-decoder evidence uses only local diagnostic paths.
        if let Some(output) = std::env::var_os("EPUB_MP3_ASSEMBLY_TEST_OUTPUT") {
            std::fs::copy(&path, output).unwrap();
        }
    }

    #[test]
    fn truncated_or_mismatched_metadata_preserves_original_bytes() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.mp3");
        let mut bytes = [AUDIO, AUDIO].concat();
        bytes.pop();
        std::fs::write(&path, &bytes).unwrap();
        assert!(finalize_mp3(&path).is_err());
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
}
