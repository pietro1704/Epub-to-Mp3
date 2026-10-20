//! PCM WAV to MP3 encoding, with normalized segments shared by native and WASM clients.

/// Parse RIFF chunks rather than assuming every writer emits a 44-byte header.
pub fn encode_wav_mp3(data: &[u8]) -> Result<Vec<u8>, String> {
    encode_wav_mp3_at_rate(data, Some(24_000))
}

/// Standalone Piper output retains its source rate and rejects unsupported MP3 rates.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn encode_wav_mp3_preserving_rate(data: &[u8]) -> Result<Vec<u8>, String> {
    encode_wav_mp3_at_rate(data, None)
}

fn encode_wav_mp3_at_rate(data: &[u8], output_rate: Option<u32>) -> Result<Vec<u8>, String> {
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
    let target_rate = output_rate.unwrap_or(rate);
    let resampled;
    let normalized = if rate == target_rate {
        pcm
    } else {
        // Multiply before division in 64 bits: ordinary utterances exceed the
        // intermediate usize range on browser WASM, even though their output fits.
        let count = (sample_count as u64)
            .checked_mul(u64::from(target_rate))
            .ok_or("PCM size overflow")?
            / u64::from(rate);
        let count = usize::try_from(count).map_err(|_| "PCM size overflow")?;
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
    #[cfg(not(target_arch = "wasm32"))]
    let encoded =
        crate::audio::collect_rusty_mp3_output(&mut encoder).map_err(|error| error.to_string())?;
    #[cfg(target_arch = "wasm32")]
    let encoded = {
        let mut encoded = Vec::new();
        while let Ok(packet) = encoder.next_packet() {
            encoded.extend_from_slice(&packet);
        }
        encoded
    };
    validate_mp3(&encoded)?;
    Ok(encoded)
}

pub fn validate_mp3(bytes: &[u8]) -> Result<(), String> {
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

    fn wav(rate: u32) -> Vec<u8> {
        let pcm: Vec<u8> = (0..rate / 4)
            .flat_map(|index| {
                let phase = index as f64 * 440.0 * std::f64::consts::TAU / rate as f64;
                ((phase.sin() * 8000.0) as i16).to_le_bytes()
            })
            .collect();
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&(rate * 2).to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&pcm);
        bytes
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn standalone_source_rate_and_mixed_segment_rate_remain_distinct() {
        let input = wav(22_050);
        for (encoded, expected_rate) in [
            (encode_wav_mp3_preserving_rate(&input).unwrap(), 22_050),
            (encode_wav_mp3(&input).unwrap(), 24_000),
        ] {
            let mut decoder = rusty_mp3::Mp3Decoder::new();
            decoder.push(&encoded);
            decoder.flush();
            let frame = decoder.next_frame().unwrap();
            assert_eq!(frame.sample_rate, expected_rate);
            assert_eq!(frame.channels, 1);
            assert!(!frame.samples.is_empty());
        }
        assert!(encode_wav_mp3_preserving_rate(&wav(12_345)).is_err());
    }

    #[test]
    fn supported_source_rates_produce_playable_normalized_mp3() {
        for rate in [16_000, 22_050, 24_000, 44_100, 48_000] {
            let encoded = encode_wav_mp3(&wav(rate)).unwrap();
            assert!(!encoded.starts_with(b"RIFF"));
            validate_mp3(&encoded).unwrap();
            let mut decoder = rusty_mp3::Mp3Decoder::new();
            decoder.push(&encoded);
            decoder.flush();
            let frame = decoder.next_frame().unwrap();
            assert_eq!(frame.sample_rate, 24_000);
            assert_eq!(frame.channels, 1);
            assert!(!frame.samples.is_empty());
        }
    }

    #[test]
    fn extra_riff_chunks_are_supported_and_truncated_pcm_is_rejected() {
        let mut input = wav(22_050);
        let mut extra = b"JUNK".to_vec();
        extra.extend_from_slice(&4u32.to_le_bytes());
        extra.extend_from_slice(b"test");
        input.splice(12..12, extra);
        let length = (input.len() - 8) as u32;
        input[4..8].copy_from_slice(&length.to_le_bytes());
        validate_mp3(&encode_wav_mp3(&input).unwrap()).unwrap();
        input.pop();
        assert!(encode_wav_mp3(&input).is_err());
        assert!(encode_wav_mp3(b"RIFF").is_err());
        assert!(validate_mp3(b"not MP3 audio").is_err());
    }
}
