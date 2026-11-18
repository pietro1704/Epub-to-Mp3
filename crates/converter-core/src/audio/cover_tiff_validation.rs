//! Bound TIFF metadata and retained strip/tile extents without converting colors.
use super::{audio_validation::invalid_audio, AudioError};
use std::io::Cursor;
use tiff::{decoder::Decoder, tags::Tag};

pub(super) fn validate_tiff_cover(bytes: &[u8]) -> Result<(), AudioError> {
    let invalid = |error: tiff::TiffError| invalid_audio(format!("invalid TIFF cover: {error}"));
    let mut limits = tiff::decoder::Limits::default();
    limits.decoding_buffer_size = 64 * 1024 * 1024;
    limits.intermediate_buffer_size = 64 * 1024 * 1024;
    let mut decoder = Decoder::new(Cursor::new(bytes))
        .map_err(invalid)?
        .with_limits(limits);
    let mut total_decode_bytes = 0u64;
    for _ in 0..64 {
        let (width, height) = decoder.dimensions().map_err(invalid)?;
        let channels = decoder
            .find_tag_unsigned::<u64>(Tag::SamplesPerPixel)
            .map_err(invalid)?
            .unwrap_or(1);
        let bits = decoder
            .find_tag_unsigned_vec::<u64>(Tag::BitsPerSample)
            .map_err(invalid)?
            .unwrap_or_else(|| vec![1]);
        if width == 0
            || height == 0
            || width > 8192
            || height > 8192
            || !(1..=16).contains(&channels)
            || bits.is_empty()
            || (bits.len() != 1 && bits.len() as u64 != channels)
            || bits.iter().any(|bits| !(1..=64).contains(bits))
        {
            return Err(invalid_audio(
                "TIFF cover exceeds image dimensions or sample limits",
            ));
        }
        let pixel_bits = if bits.len() == 1 {
            bits[0] * channels
        } else {
            bits.iter().sum()
        };
        total_decode_bytes += (u64::from(width) * u64::from(height) * pixel_bits).div_ceil(8);
        if total_decode_bytes > 64 * 1024 * 1024 {
            return Err(invalid_audio("TIFF cover exceeds decoded image budget"));
        }
        let tiled = decoder
            .find_tag(Tag::TileOffsets)
            .map_err(invalid)?
            .is_some();
        let offsets = decoder
            .get_tag_u64_vec(if tiled {
                Tag::TileOffsets
            } else {
                Tag::StripOffsets
            })
            .map_err(invalid)?;
        let counts = decoder
            .get_tag_u64_vec(if tiled {
                Tag::TileByteCounts
            } else {
                Tag::StripByteCounts
            })
            .map_err(invalid)?;
        if offsets.is_empty() || offsets.len() != counts.len() {
            return Err(invalid_audio("invalid TIFF cover strip/tile table"));
        }
        for (offset, count) in offsets.into_iter().zip(counts) {
            if count == 0
                || offset < 8
                || offset
                    .checked_add(count)
                    .is_none_or(|end| end > bytes.len() as u64)
            {
                return Err(invalid_audio("truncated TIFF cover strip/tile"));
            }
        }
        if !decoder.more_images() {
            return Ok(());
        }
        decoder.next_image().map_err(invalid)?;
    }
    Err(invalid_audio("TIFF cover exceeds image count limit"))
}
