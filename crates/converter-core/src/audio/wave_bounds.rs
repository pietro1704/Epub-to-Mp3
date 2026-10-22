//! Validate RIFF chunk bounds and complete WAV sample frames.
use super::audio_validation::invalid_audio;
use super::AudioError;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

pub(super) fn validate_wave_bounds(file: &mut File) -> Result<(), AudioError> {
    file.seek(SeekFrom::Start(4))?;
    let mut size = [0u8; 4];
    file.read_exact(&mut size)?;
    let end = u64::from(u32::from_le_bytes(size)) + 8;
    if end > file.metadata()?.len() || end < 12 {
        return Err(invalid_audio("truncated RIFF container"));
    }
    let mut offset = 12;
    let mut data_bytes = 0;
    let mut alignment = 0u16;
    let mut format_tag = 0u16;
    while offset < end {
        if end - offset < 8 {
            return Err(invalid_audio("truncated WAV chunk header"));
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut header = [0u8; 8];
        file.read_exact(&mut header)?;
        let size = u64::from(u32::from_le_bytes(header[4..8].try_into().unwrap()));
        let next = offset
            .checked_add(8 + size + size % 2)
            .ok_or_else(|| invalid_audio("WAV chunk overflows"))?;
        if next > end {
            return Err(invalid_audio("truncated WAV chunk"));
        }
        if &header[..4] == b"fmt " {
            if size < 16 {
                return Err(invalid_audio("incomplete WAV format"));
            }
            file.seek(SeekFrom::Start(offset + 8))?;
            let mut tag = [0u8; 2];
            file.read_exact(&mut tag)?;
            format_tag = u16::from_le_bytes(tag);
            file.seek(SeekFrom::Start(offset + 8 + 12))?;
            let mut block = [0u8; 2];
            file.read_exact(&mut block)?;
            alignment = u16::from_le_bytes(block);
        }
        if &header[..4] == b"data" {
            data_bytes += size;
        }
        offset = next;
    }
    if data_bytes == 0
        || alignment == 0
        || (matches!(format_tag, 1 | 3) && data_bytes % u64::from(alignment) != 0)
    {
        return Err(invalid_audio("WAV has incomplete sample frames"));
    }
    Ok(())
}
