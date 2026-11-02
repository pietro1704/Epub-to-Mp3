use super::*;

fn raw_edge_shaped_audio(speech: usize, silence: usize) -> Vec<u8> {
    let mut encoder = rusty_mp3::Mp3Encoder::new(rusty_mp3::Mp3EncoderConfig {
        bitrate_kbps: 48,
        vbr_quality: None,
    });
    let pcm = (0..speech + silence)
        .flat_map(|index| {
            let sample = if index < speech {
                if index % 48 < 24 {
                    4000i16
                } else {
                    -4000i16
                }
            } else {
                0
            };
            sample.to_le_bytes()
        })
        .collect::<Vec<_>>();
    encoder.push_pcm_s16le(&pcm, 1, 24_000).unwrap();
    encoder.finish();
    let tagged = collect_rusty_mp3_output(&mut encoder).unwrap();
    let header = rusty_mp3::header::FrameHeader::parse(tagged[..4].try_into().unwrap()).unwrap();
    tagged[header.frame_size()..].to_vec()
}

#[test]
fn edge_padding_removes_only_complete_silent_tail_frames() {
    let original = raw_edge_shaped_audio(24_000, 24_000);
    let mut trimmed = original.clone();
    trim_edge_trailing_silence(&mut trimmed);
    assert!(trimmed.len() < original.len() * 3 / 4);
    assert!(
        original.starts_with(&trimmed),
        "Speech frames must not be re-encoded"
    );
    validate_mp3(&trimmed).unwrap();
    let length = trimmed.len();
    trim_edge_trailing_silence(&mut trimmed);
    assert_eq!(trimmed.len(), length, "Trimming is idempotent");

    if let Some(directory) = std::env::var_os("EPUB_EDGE_PADDING_FIXTURES") {
        for entry in std::fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().and_then(|value| value.to_str()) != Some("mp3") {
                continue;
            }
            let original = std::fs::read(&path).unwrap();
            let mut trimmed = original.clone();
            trim_edge_trailing_silence(&mut trimmed);
            assert!(
                trimmed.len() < original.len(),
                "Captured Edge padding must be reduced"
            );
            assert!(original.starts_with(&trimmed));
            validate_mp3(&trimmed).unwrap();
            std::fs::write(path.with_extension("trimmed-mp3"), trimmed).unwrap();
        }
    }
}

#[test]
fn edge_padding_preserves_speech_short_pauses_silence_and_invalid_input() {
    for original in [
        raw_edge_shaped_audio(24_000, 1200),
        raw_edge_shaped_audio(0, 24_000),
        b"invalid MP3".to_vec(),
    ] {
        let mut actual = original.clone();
        trim_edge_trailing_silence(&mut actual);
        assert_eq!(actual, original);
    }
}

#[test]
fn source_rate_encoding_preserves_mpeg_rates_and_rejects_unsupported_rates() {
    for rate in [22_050, 24_000, 44_100] {
        let encoded = encode_wav_mp3_at_source_rate(&wav(rate)).unwrap();
        let mut decoder = rusty_mp3::Mp3Decoder::new();
        decoder.push(&encoded);
        decoder.flush();
        assert_eq!(decoder.next_frame().unwrap().sample_rate, rate);
    }
    assert!(encode_wav_mp3_at_source_rate(&wav(12_345)).is_err());
}

#[test]
fn standalone_chapters_above_segment_duration_limit_remain_playable() {
    let rate = 22_050u32;
    let mut input = wav(rate);
    let payload = input[44..].to_vec();
    input.truncate(44);
    // Repeat the quarter-second fixture to produce a 121-second chapter.
    for _ in 0..485 {
        input.extend_from_slice(&payload);
    }
    input.truncate(44 + rate as usize * 121 * 2);
    let payload_len = (input.len() - 44) as u32;
    input[4..8].copy_from_slice(&(36 + payload_len).to_le_bytes());
    input[40..44].copy_from_slice(&payload_len.to_le_bytes());
    assert!(payload_len as usize / 2 > rate as usize * 120);
    assert_eq!(
        encode_wav_mp3(&input).unwrap_err(),
        "System speech PCM exceeds the segment duration limit"
    );

    let encoded = encode_wav_mp3_at_source_rate(&input).unwrap();
    let header = rusty_mp3::header::FrameHeader::parse(encoded[..4].try_into().unwrap()).unwrap();
    let field = 4 + usize::from(header.crc_protected) * 2 + header.side_info_len() + 8;
    let declared_bytes = u32::from_be_bytes(encoded[field + 4..field + 8].try_into().unwrap());
    assert_eq!(declared_bytes as usize, encoded.len());
    let mut decoder = rusty_mp3::Mp3Decoder::new();
    decoder.push(&encoded);
    decoder.flush();
    let frame = decoder.next_frame().unwrap();
    assert_eq!(frame.sample_rate, rate);
    assert_eq!(frame.channels, 1);
    assert!(!frame.samples.is_empty());
}

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
        let header = rusty_mp3::header::FrameHeader::parse(
            encoded[position..position + 4].try_into().unwrap(),
        )
        .unwrap();
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
#[cfg(not(target_arch = "wasm32"))]
fn standalone_source_rate_and_mixed_segment_rate_remain_distinct() {
    let input = wav(22_050);
    for (encoded, expected_rate) in [
        (encode_wav_mp3_at_source_rate(&input).unwrap(), 22_050),
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
    assert!(encode_wav_mp3_at_source_rate(&wav(12_345)).is_err());
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
