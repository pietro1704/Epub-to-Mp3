//! Platform speech adapter. Rust retains segmentation, encoding and publication.
use std::path::Path;

pub trait PlatformTts: Send + Sync {
    /// Write mono signed 16-bit PCM WAV. Poll cancellation while waiting for speech.
    fn synthesize_wav(
        &self,
        text: &str,
        language: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), String>;
}

/// Small initial utterance bounds startup work; later utterances bound memory.
pub(crate) fn segments(text: &str) -> Vec<String> {
    split_segments(text, 180, 800)
}

/// Compact utterances keep legacy system voices below their per-call deadline.
pub(crate) fn native_segments(text: &str, first: bool) -> Vec<String> {
    split_segments(text, if first { 60 } else { 240 }, 240)
}

fn split_segments(text: &str, initial: usize, subsequent: usize) -> Vec<String> {
    let mut result = Vec::new();
    let mut pending = text.trim();
    while !pending.is_empty() {
        let limit = if result.is_empty() {
            initial
        } else {
            subsequent
        };
        let end = pending
            .char_indices()
            .nth(limit)
            .map(|(offset, _)| offset)
            .unwrap_or(pending.len());
        let prefix = &pending[..end];
        let boundary = if end == pending.len() {
            end
        } else {
            prefix
                .char_indices()
                .rev()
                .find(|(_, c)| c.is_whitespace() || matches!(c, '.' | '?' | '!'))
                .map(|(offset, c)| offset + c.len_utf8())
                .filter(|offset| *offset > end / 2)
                .unwrap_or(end)
        };
        result.push(pending[..boundary].trim().to_owned());
        pending = pending[boundary..].trim_start();
    }
    result
}

/// Parse RIFF chunks rather than assuming every writer emits a 44-byte header.
pub(crate) fn encode_wav(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() < 12 || &data[..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return Err("Invalid WAV header".into());
    }
    let riff_end = (u32::from_le_bytes(data[4..8].try_into().unwrap()) as usize)
        .checked_add(8)
        .ok_or("Invalid WAV length")?;
    if riff_end > data.len() {
        return Err("Truncated WAV".into());
    }
    let mut format = None;
    let mut pcm = None;
    let mut position = 12usize;
    while position + 8 <= riff_end {
        let length =
            u32::from_le_bytes(data[position + 4..position + 8].try_into().unwrap()) as usize;
        let start = position + 8;
        let end = start
            .checked_add(length)
            .filter(|end| *end <= riff_end)
            .ok_or("Truncated WAV chunk")?;
        match &data[position..position + 4] {
            b"fmt " if length >= 16 => {
                let chunk = &data[start..end];
                let codec = u16::from_le_bytes(chunk[..2].try_into().unwrap());
                let channels = u16::from_le_bytes(chunk[2..4].try_into().unwrap());
                let rate = u32::from_le_bytes(chunk[4..8].try_into().unwrap());
                let bits = u16::from_le_bytes(chunk[14..16].try_into().unwrap());
                if codec != 1 || channels != 1 || bits != 16 || !(8_000..=96_000).contains(&rate) {
                    return Err("Expected mono 16-bit PCM WAV".into());
                }
                format = Some((channels, rate));
            }
            b"data" => pcm = Some(&data[start..end]),
            _ => {}
        }
        position = end.checked_add(length % 2).ok_or("Invalid WAV chunk")?;
    }
    let (channels, rate) = format.ok_or("Missing WAV format")?;
    let pcm = pcm
        .filter(|pcm| !pcm.is_empty() && pcm.len() % 2 == 0)
        .ok_or("Missing or invalid WAV PCM")?;
    let sample_count = pcm.len() / 2;
    if sample_count > rate as usize * 120 {
        return Err("System speech PCM exceeds the segment duration limit".into());
    }
    // Edge emits 24 kHz MP3. Keep concatenated fallback artifacts at that rate.
    let target_rate = 24_000u32;
    let resampled;
    let normalized = if rate == target_rate {
        pcm
    } else {
        let count = sample_count
            .checked_mul(target_rate as usize)
            .ok_or("PCM size overflow")?
            / rate as usize;
        let capacity = count.checked_mul(2).ok_or("PCM size overflow")?;
        let mut output = Vec::with_capacity(capacity);
        let sample = |index: usize| {
            i16::from_le_bytes(pcm[index * 2..index * 2 + 2].try_into().unwrap()) as f64
        };
        for index in 0..count {
            let position = index as f64 * rate as f64 / target_rate as f64;
            let left = (position as usize).min(sample_count - 1);
            let right = (left + 1).min(sample_count - 1);
            let fraction = position - left as f64;
            let value = (sample(left) + (sample(right) - sample(left)) * fraction)
                .round()
                .clamp(i16::MIN as f64, i16::MAX as f64) as i16;
            output.extend_from_slice(&value.to_le_bytes());
        }
        resampled = output;
        resampled.as_slice()
    };
    let mut encoder = rusty_mp3::Mp3Encoder::new(rusty_mp3::Mp3EncoderConfig {
        bitrate_kbps: 96,
        vbr_quality: None,
    });
    encoder
        .push_pcm_s16le(normalized, channels, target_rate)
        .map_err(|error| error.to_string())?;
    encoder.finish();
    let mut encoded = Vec::new();
    while let Ok(packet) = encoder.next_packet() {
        encoded.extend_from_slice(&packet);
    }
    validate_mp3(&encoded)?;
    Ok(encoded)
}

pub(crate) fn validate_mp3(bytes: &[u8]) -> Result<(), String> {
    let mut decoder = rusty_mp3::Mp3Decoder::new();
    decoder.push(bytes);
    decoder.flush();
    let mut samples = 0;
    while let Ok(frame) = decoder.next_frame() {
        samples += frame.samples.len();
    }
    if samples == 0 {
        return Err("Speech produced no playable MP3 frames".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_segments_preserve_words_and_bound_startup() {
        let text = "Olá, ação e coração. ".repeat(150);
        let pieces = segments(&text);
        assert!(pieces[0].chars().count() <= 180);
        assert!(pieces.iter().all(|piece| piece.chars().count() <= 800));
        assert_eq!(pieces.join(" "), text.trim());
    }
    #[test]
    fn malformed_audio_is_rejected() {
        assert!(encode_wav(b"RIFF").is_err());
        assert!(validate_mp3(b"not audio").is_err());
    }
}
