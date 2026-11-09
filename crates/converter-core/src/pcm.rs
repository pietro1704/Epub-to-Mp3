//! PCM WAV to MP3 encoding, with normalized segments shared by native and WASM clients.

fn encoder_error(message: impl Into<String>) -> String {
    message.into()
}

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
    // Edge emits 24 kHz MP3. Keep concatenated fallback artifacts at that rate.
    encode_wav_mp3_at_rate(data, Some(24_000), false)
}

pub(crate) fn encode_speech_wav_mp3(data: &[u8]) -> Result<Vec<u8>, String> {
    encode_wav_mp3_at_rate(data, Some(24_000), true)
}

/// Preserve the legacy single-provider source rate and the encoder's rate validation.
pub(crate) fn encode_wav_mp3_at_source_rate(data: &[u8]) -> Result<Vec<u8>, String> {
    encode_wav_mp3_at_rate(data, None, false)
}

fn encode_wav_mp3_at_rate(
    data: &[u8],
    target_rate: Option<u32>,
    compact: bool,
) -> Result<Vec<u8>, String> {
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
    let mut alignment_json = None;
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
            b"spch" => alignment_json = Some(&data[start..end]),
            _ => {}
        }
        position = end.checked_add(length % 2).ok_or("Invalid WAV chunk")?;
    }
    let (channels, rate) = format.ok_or("Missing WAV format")?;
    let pcm = pcm
        .filter(|pcm| !pcm.is_empty() && pcm.len() % 2 == 0)
        .ok_or("Missing or invalid WAV PCM")?;
    let sample_count = pcm.len() / 2;
    // Optional display metadata cannot make a working system voice unavailable.
    // Invalid markers are discarded while the PCM keeps its normal validation.
    let mut alignment = alignment_json.and_then(|json| {
        crate::speech_alignment::Passage::parse(json, sample_count as f64 / f64::from(rate)).ok()
    });
    if target_rate.is_some() && sample_count > rate as usize * 120 {
        return Err("System speech PCM exceeds the segment duration limit".into());
    }
    let compacted;
    let pcm = if compact {
        if let Some(alignment) = &mut alignment {
            alignment.compact(pcm, rate);
        }
        compacted = crate::speech_silence::compact(pcm, rate)?;
        compacted.as_slice()
    } else {
        pcm
    };
    let sample_count = pcm.len() / 2;
    let target_rate = target_rate.unwrap_or(rate);
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
    if let Some(alignment) = alignment.filter(|value| !value.words.is_empty()) {
        let mut tagged = crate::speech_alignment::tag(&[alignment])?;
        tagged.extend(encoded);
        Ok(tagged)
    } else {
        Ok(encoded)
    }
}

pub fn validate_mp3(bytes: &[u8]) -> Result<(), String> {
    mp3_duration_seconds(bytes).map(|_| ())
}

pub fn mp3_duration_seconds(bytes: &[u8]) -> Result<f64, String> {
    let mut decoder = rusty_mp3::Mp3Decoder::new();
    decoder.push(bytes);
    decoder.flush();
    let mut duration = 0.0;
    while let Ok(frame) = decoder.next_frame() {
        if frame.channels == 0 || frame.sample_rate == 0 {
            return Err("Invalid MP3 audio format".into());
        }
        duration +=
            frame.samples.len() as f64 / f64::from(frame.channels) / frame.sample_rate as f64;
    }
    if duration <= 0.0 {
        return Err("Speech produced no playable MP3 frames".into());
    }
    Ok(duration)
}

/// Edge appends a long silent tail to each independent response. Remove only
/// complete trailing silent MPEG frames, retaining 120 ms after the last sample
/// above -80 dB. The speech payload, decoder pre-roll and natural internal pauses
/// stay byte-identical. Tagged/variable-format streams are left unchanged.
pub(crate) fn trim_edge_trailing_silence(bytes: &mut Vec<u8>) {
    let mut frames = Vec::new();
    let mut offset = 0;
    let mut samples = 0usize;
    let mut rate = None;
    while offset < bytes.len() {
        let Some(header_bytes) = bytes.get(offset..offset + 4) else {
            return;
        };
        let Ok(header) = rusty_mp3::header::FrameHeader::parse(header_bytes.try_into().unwrap())
        else {
            return;
        };
        if rate.is_some_and(|value| value != header.sample_rate) {
            return;
        }
        rate = Some(header.sample_rate);
        let end = offset + header.frame_size();
        let Some(frame) = bytes.get(offset..end) else {
            return;
        };
        if offset == 0 {
            let tag = 4 + usize::from(header.crc_protected) * 2 + header.side_info_len();
            if frame
                .get(tag..tag + 4)
                .is_some_and(|value| value == b"Xing" || value == b"Info")
            {
                return;
            }
        }
        samples += header.version.samples_per_frame();
        frames.push((end, samples));
        offset = end;
    }
    let Some(rate) = rate else { return };
    let mut decoder = rusty_mp3::Mp3Decoder::new();
    decoder.push(bytes);
    decoder.flush();
    let mut decoded_samples = 0usize;
    let mut last_audible = None;
    while let Ok(frame) = decoder.next_frame() {
        if frame.sample_rate != rate || frame.channels == 0 {
            return;
        }
        let channels = usize::from(frame.channels);
        for (index, sample_frame) in frame.samples.chunks_exact(channels).enumerate() {
            if sample_frame
                .iter()
                .any(|sample| !sample.is_finite() || sample.abs() > 0.0001)
            {
                last_audible = Some(decoded_samples + index + 1);
            }
        }
        decoded_samples += frame.samples.len() / channels;
    }
    if decoded_samples != samples {
        return;
    }
    let Some(last_audible) = last_audible else {
        return;
    };
    if samples.saturating_sub(last_audible) < rate as usize / 4 {
        return;
    }
    let keep = last_audible.saturating_add(rate as usize * 120 / 1000);
    if let Some((end, _)) = frames.into_iter().find(|(_, count)| *count >= keep) {
        bytes.truncate(end);
    }
}

#[cfg(test)]
mod tests;
