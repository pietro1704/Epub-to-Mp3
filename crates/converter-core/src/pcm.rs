//! Platform-independent PCM WAV to normalized MP3 encoding shared by native and WASM clients.

fn encoder_error(message: impl Into<String>) -> String { message.into() }

/// Collect a finished rusty_mp3 1.0.0 encoder without changing MPEG audio payloads.
/// That producer counts the Info/Xing metadata frame itself, unlike the audio-frame
/// count consumed by MPEG readers. Normalize only this known encoder's output.
pub(crate) fn collect_rusty_mp3_output(
    encoder: &mut rusty_mp3::Mp3Encoder,
) -> Result<Vec<u8>, String> {
    let mut encoded = Vec::new();
    let mut packets = 0u32;
    let mut count_offset = None;
    loop {
        let packet = match encoder.next_packet() {
            Ok(packet) => packet,
            Err(rusty_mp3::Error::Eof) => break,
            Err(error) => {
                return Err(encoder_error(format!(
                    "MP3 encoder did not finish: {error}"
                )))
            }
        };
        let bytes: [u8; 4] = packet
            .get(..4)
            .ok_or_else(|| encoder_error("MP3 encoder emitted a short frame"))?
            .try_into()
            .unwrap();
        let header = rusty_mp3::header::FrameHeader::parse(bytes).map_err(|error| {
            encoder_error(format!("MP3 encoder emitted an invalid frame: {error}"))
        })?;
        if header.frame_size() != packet.len() {
            return Err(encoder_error("MP3 encoder emitted an incomplete frame"));
        }
        if packets == 0 {
            let tag = 4 + usize::from(header.crc_protected) * 2 + header.side_info_len();
            let metadata = packet
                .get(tag..tag + 16)
                .ok_or_else(|| encoder_error("MP3 encoder omitted Info/Xing counts"))?;
            if (&metadata[..4] != b"Info" && &metadata[..4] != b"Xing")
                || metadata[4..8] != 3u32.to_be_bytes()
            {
                return Err(encoder_error(
                    "MP3 encoder emitted unexpected Info/Xing flags",
                ));
            }
            count_offset = Some(tag + 8);
        }
        packets = packets
            .checked_add(1)
            .ok_or_else(|| encoder_error("MP3 encoder frame count overflows"))?;
        encoded.extend_from_slice(&packet);
    }
    let field = count_offset.ok_or_else(|| encoder_error("MP3 encoder emitted no frames"))?;
    let declared = u32::from_be_bytes(encoded[field..field + 4].try_into().unwrap());
    let declared_bytes = u32::from_be_bytes(encoded[field + 4..field + 8].try_into().unwrap());
    if packets < 2 || declared != packets || u64::from(declared_bytes) != encoded.len() as u64 {
        return Err(encoder_error(
            "MP3 encoder Info/Xing counts do not match emitted frames",
        ));
    }
    encoded[field..field + 4].copy_from_slice(&(packets - 1).to_be_bytes());
    Ok(encoded)
}

/// Parse RIFF chunks rather than assuming every writer emits a 44-byte header.
pub fn encode_wav_mp3(data: &[u8]) -> Result<Vec<u8>, String> {
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
    let encoded = collect_rusty_mp3_output(&mut encoder)?;
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

    #[test]
    fn portable_encoder_declares_only_audio_frames_and_retains_total_byte_length() {
        let encoded = encode_wav_mp3(&wav(24_000)).unwrap();
        let header = rusty_mp3::header::FrameHeader::parse(encoded[..4].try_into().unwrap()).unwrap();
        let field = 4 + usize::from(header.crc_protected) * 2 + header.side_info_len() + 8;
        let declared_frames = u32::from_be_bytes(encoded[field..field + 4].try_into().unwrap());
        let declared_bytes = u32::from_be_bytes(encoded[field + 4..field + 8].try_into().unwrap());
        let mut position = 0;
        let mut physical_frames = 0;
        while position < encoded.len() {
            let header = rusty_mp3::header::FrameHeader::parse(encoded[position..position + 4].try_into().unwrap()).unwrap();
            position += header.frame_size();
            physical_frames += 1;
        }
        assert_eq!(position, encoded.len());
        assert_eq!(declared_frames + 1, physical_frames);
        assert_eq!(declared_bytes as usize, encoded.len());
        validate_mp3(&encoded).unwrap();
    }



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
