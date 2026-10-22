//! Bounded MPEG frame extents, metadata counts and validated-inode streams.
use super::audio_validation::invalid_audio;
use super::AudioError;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct MpegSegment {
    pub(super) start: u64,
    pub(super) length: u64,
}

/// A file-backed logical stream that cannot expose neighboring ID3/audio bytes.
pub(super) struct AudioSegmentSource {
    file: File,
    segment: MpegSegment,
    position: u64,
}

impl AudioSegmentSource {
    pub(super) fn new(mut file: File, segment: MpegSegment) -> io::Result<Self> {
        let end = segment
            .start
            .checked_add(segment.length)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "audio extent overflow"))?;
        if end > file.metadata()?.len() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "truncated audio extent",
            ));
        }
        file.seek(SeekFrom::Start(segment.start))?;
        Ok(Self {
            file,
            segment,
            position: 0,
        })
    }
}

impl Read for AudioSegmentSource {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let remaining = self.segment.length - self.position;
        let length = buffer
            .len()
            .min(usize::try_from(remaining).unwrap_or(usize::MAX));
        let count = self.file.read(&mut buffer[..length])?;
        self.position += count as u64;
        Ok(count)
    }
}

impl Seek for AudioSegmentSource {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        let target = match from {
            SeekFrom::Start(offset) => i128::from(offset),
            SeekFrom::Current(offset) => i128::from(self.position) + i128::from(offset),
            SeekFrom::End(offset) => i128::from(self.segment.length) + i128::from(offset),
        };
        if target < 0 || target > i128::from(self.segment.length) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek outside audio extent",
            ));
        }
        let target = target as u64;
        self.file
            .seek(SeekFrom::Start(self.segment.start + target))?;
        self.position = target;
        Ok(target)
    }
}

impl symphonia::core::io::MediaSource for AudioSegmentSource {
    fn is_seekable(&self) -> bool {
        true
    }
    fn byte_len(&self) -> Option<u64> {
        Some(self.segment.length)
    }
}

#[derive(Default)]
pub(super) struct MpegFrameCount {
    frames: u64,
    metadata: bool,
    expected_frames: Option<u64>,
    expected_bytes: Option<u64>,
}

impl MpegFrameCount {
    fn finish(&self, start: u64, end: u64) -> Result<MpegSegment, AudioError> {
        let audio_frames = self.frames.saturating_sub(u64::from(self.metadata));
        if audio_frames == 0 {
            return Err(invalid_audio("MPEG segment has no audio frames"));
        }
        if self
            .expected_frames
            .is_some_and(|expected| expected != audio_frames)
        {
            return Err(invalid_audio(
                "MPEG frame count does not match Info/Xing declaration",
            ));
        }
        if self
            .expected_bytes
            .is_some_and(|expected| expected != end - start)
        {
            return Err(invalid_audio(
                "MPEG byte count does not match Info/Xing declaration",
            ));
        }
        Ok(MpegSegment {
            start,
            length: end - start,
        })
    }
}

pub(super) fn mpeg_info_counts(
    file: &mut File,
    offset: u64,
    length: u64,
    bits: u32,
) -> Result<Option<MpegFrameCount>, AudioError> {
    let mpeg1 = (bits >> 19) & 3 == 3;
    let mono = (bits >> 6) & 3 == 3;
    let side = match (mpeg1, mono) {
        (true, true) => 17,
        (true, false) => 32,
        (false, true) => 9,
        (false, false) => 17,
    };
    // LAME retains its Info/Xing offset when CRC is present; also accept
    // encoders that place the optional two CRC bytes before side information.
    for position in [4 + side, 6 + side] {
        if position == 6 + side && (bits >> 16) & 1 != 0 {
            continue;
        }
        if position + 8 > length {
            continue;
        }
        file.seek(SeekFrom::Start(offset + position))?;
        let mut header = [0u8; 8];
        file.read_exact(&mut header)?;
        if &header[..4] != b"Info" && &header[..4] != b"Xing" {
            continue;
        }
        let flags = u32::from_be_bytes(header[4..].try_into().unwrap());
        let fields = u64::from(flags & 1 != 0) + u64::from(flags & 2 != 0);
        if position + 8 + fields * 4 > length {
            return Err(invalid_audio("truncated Info/Xing frame counts"));
        }
        let mut count = MpegFrameCount {
            metadata: true,
            ..MpegFrameCount::default()
        };
        for (flag, target) in [
            (1, &mut count.expected_frames),
            (2, &mut count.expected_bytes),
        ] {
            if flags & flag != 0 {
                let mut value = [0u8; 4];
                file.read_exact(&mut value)?;
                *target = Some(u64::from(u32::from_be_bytes(value)));
            }
        }
        return Ok(Some(count));
    }
    Ok(None)
}

pub(super) fn validate_mpeg_bounds(file: &mut File) -> Result<Vec<MpegSegment>, AudioError> {
    let mut end = file.metadata()?.len();
    if end >= 128 {
        file.seek(SeekFrom::Start(end - 128))?;
        let mut tag = [0u8; 3];
        file.read_exact(&mut tag)?;
        if &tag == b"TAG" {
            end -= 128;
        }
    }
    if end >= 32 {
        file.seek(SeekFrom::Start(end - 32))?;
        let mut footer = [0u8; 32];
        file.read_exact(&mut footer)?;
        if &footer[..8] == b"APETAGEX" {
            let size = u64::from(u32::from_le_bytes(footer[12..16].try_into().unwrap()));
            if size < 32 || size > end {
                return Err(invalid_audio("invalid APE tag extent"));
            }
            end -= size;
            if end >= 32 {
                file.seek(SeekFrom::Start(end - 32))?;
                let mut header = [0u8; 8];
                file.read_exact(&mut header)?;
                if &header == b"APETAGEX" {
                    end -= 32;
                }
            }
        }
    }
    let mut offset = 0u64;
    let mut segments = Vec::new();
    let mut segment_start = 0;
    let mut count = MpegFrameCount::default();
    while offset < end {
        if end - offset < 4 {
            return Err(invalid_audio("truncated MPEG frame header"));
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut header = [0u8; 4];
        file.read_exact(&mut header)?;
        if &header[..3] == b"ID3" {
            if count.frames != 0 {
                segments.push(count.finish(segment_start, offset)?);
                count = MpegFrameCount::default();
            }
            if end - offset < 10 {
                return Err(invalid_audio("truncated ID3 header"));
            }
            let mut rest = [0u8; 6];
            file.read_exact(&mut rest)?;
            if rest[2..].iter().any(|byte| byte & 0x80 != 0) {
                return Err(invalid_audio("invalid ID3 tag size"));
            }
            let size = rest[2..]
                .iter()
                .fold(0u64, |size, byte| size * 128 + u64::from(*byte));
            let footer = if header[3] == 4 && rest[1] & 0x10 != 0 {
                10
            } else {
                0
            };
            offset += 10 + size + footer;
            if offset > end {
                return Err(invalid_audio("truncated ID3 tag"));
            }
            segment_start = offset;
            continue;
        }
        let bits = u32::from_be_bytes(header);
        let version = (bits >> 19) & 3;
        let layer = (bits >> 17) & 3;
        let bitrate_index = ((bits >> 12) & 15) as usize;
        let rate_index = ((bits >> 10) & 3) as usize;
        if bits >> 21 != 0x7ff
            || version == 1
            || layer != 1
            || bitrate_index == 0
            || bitrate_index == 15
            || rate_index == 3
        {
            return Err(invalid_audio("invalid MPEG Layer III frame"));
        }
        let rates = [44100u64, 48000, 32000];
        let rate = rates[rate_index]
            / match version {
                3 => 1,
                2 => 2,
                _ => 4,
            };
        let mpeg1 = [
            0u64, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
        ];
        let mpeg2 = [
            0u64, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
        ];
        let bitrate = if version == 3 {
            mpeg1[bitrate_index]
        } else {
            mpeg2[bitrate_index]
        };
        let length = (if version == 3 { 144000 } else { 72000 }) * bitrate / rate
            + u64::from((bits >> 9) & 1);
        if length > end - offset {
            return Err(invalid_audio("truncated MPEG frame payload"));
        }
        if let Some(metadata) = mpeg_info_counts(file, offset, length, bits)? {
            if count.frames != 0 {
                segments.push(count.finish(segment_start, offset)?);
            }
            segment_start = offset;
            count = metadata;
        }
        offset += length;
        count.frames += 1;
    }
    if count.frames != 0 {
        segments.push(count.finish(segment_start, offset)?);
    }
    if segments.is_empty() {
        return Err(invalid_audio("MPEG audio has no frames"));
    }
    Ok(segments)
}
