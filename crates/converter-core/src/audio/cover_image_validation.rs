//! Validate compressed cover-container extents before image decoding.
use super::audio_validation::invalid_audio;
use super::AudioError;

pub(super) fn validate_cover_container(
    bytes: &[u8],
    format: image::ImageFormat,
) -> Result<(), AudioError> {
    match format {
        image::ImageFormat::Png => {
            let mut offset = 8usize;
            loop {
                if bytes.len().saturating_sub(offset) < 12 {
                    return Err(invalid_audio("truncated PNG cover"));
                }
                let length =
                    u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
                let next = offset
                    .checked_add(12)
                    .and_then(|offset| offset.checked_add(length))
                    .filter(|next| *next <= bytes.len())
                    .ok_or_else(|| invalid_audio("truncated PNG cover chunk"))?;
                if &bytes[offset + 4..offset + 8] == b"IEND" {
                    if length != 0 {
                        return Err(invalid_audio("invalid PNG cover terminator"));
                    }
                    if bytes[next - 4..next] != [0xae, 0x42, 0x60, 0x82] {
                        return Err(invalid_audio("invalid PNG cover terminator checksum"));
                    }
                    break;
                }
                offset = next;
            }
        }
        image::ImageFormat::Jpeg => validate_jpeg_extent(bytes)?,
        image::ImageFormat::WebP => {
            if bytes.len() < 12
                || u64::from(u32::from_le_bytes(bytes[4..8].try_into().unwrap())) + 8
                    != bytes.len() as u64
            {
                return Err(invalid_audio("truncated WebP cover"));
            }
        }
        _ => {}
    }
    Ok(())
}

fn validate_jpeg_extent(bytes: &[u8]) -> Result<(), AudioError> {
    let mut position = 2usize;
    let mut has_scan = false;
    while position < bytes.len() {
        if bytes[position] != 0xff {
            return Err(invalid_audio("invalid JPEG marker"));
        }
        while position < bytes.len() && bytes[position] == 0xff {
            position += 1;
        }
        let marker = *bytes
            .get(position)
            .ok_or_else(|| invalid_audio("truncated JPEG marker"))?;
        position += 1;
        if marker == 0xd9 {
            return if has_scan {
                Ok(())
            } else {
                Err(invalid_audio("JPEG has no scan"))
            };
        }
        if marker == 0x01 || (0xd0..=0xd7).contains(&marker) {
            continue;
        }
        if marker == 0xd8 || marker == 0 {
            return Err(invalid_audio("invalid JPEG marker ordering"));
        }
        let length_bytes = bytes
            .get(position..position + 2)
            .ok_or_else(|| invalid_audio("truncated JPEG segment"))?;
        let length = usize::from(u16::from_be_bytes(length_bytes.try_into().unwrap()));
        if length < 2 {
            return Err(invalid_audio("invalid JPEG segment length"));
        }
        position = position
            .checked_add(length)
            .filter(|end| *end <= bytes.len())
            .ok_or_else(|| invalid_audio("truncated JPEG segment"))?;
        if marker == 0xda {
            has_scan = true;
            while position < bytes.len() {
                if bytes[position] != 0xff {
                    position += 1;
                    continue;
                }
                let start = position;
                while position < bytes.len() && bytes[position] == 0xff {
                    position += 1;
                }
                let next = *bytes
                    .get(position)
                    .ok_or_else(|| invalid_audio("truncated JPEG scan"))?;
                if next == 0 || (0xd0..=0xd7).contains(&next) {
                    position += 1;
                    continue;
                }
                position = start;
                break;
            }
        }
    }
    Err(invalid_audio("truncated main JPEG image"))
}
