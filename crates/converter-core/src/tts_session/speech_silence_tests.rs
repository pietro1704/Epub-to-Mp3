use super::*;

fn pcm_sink(samples: &[i16], rate: u32) -> AudioSink {
    let mut sink = AudioSink::new(
        AudioFormat::Pcm16 {
            sample_rate: rate,
            channels: 1,
        },
        MAX_SEGMENT_BYTES,
    );
    let bytes: Vec<_> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    sink.write(&bytes).unwrap();
    sink
}

#[test]
fn synthesis_sink_compacts_long_silence_before_encoding() {
    let rate = 24_000;
    let mut samples = vec![4_000; rate / 2];
    samples.extend(vec![0; rate * 2]);
    samples.extend(vec![4_000; rate / 2]);
    let mp3 = pcm_sink(&samples, rate as u32).into_mp3().unwrap();
    let duration = crate::pcm::mp3_duration_seconds(&mp3).unwrap();
    assert!((1.25..1.45).contains(&duration), "duration: {duration}");
}

#[test]
fn explicit_structural_silence_is_not_compacted() {
    let mp3 = encode_pcm_f32(&vec![0.0; 19_200], 24_000).unwrap();
    let duration = crate::pcm::mp3_duration_seconds(&mp3).unwrap();
    assert!((0.8..0.95).contains(&duration));
}

#[test]
fn wav_provider_uses_compaction_but_preencoded_mp3_is_preserved() {
    // A complete PCM WAV fixture with an ancillary chunk exercises RIFF parsing.
    let mut samples = vec![3_000_i16; 12_000];
    samples.extend(vec![0; 48_000]);
    samples.extend(vec![-3_000; 12_000]);
    let pcm: Vec<_> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    let mut wav = b"RIFF".to_vec();
    wav.extend_from_slice(&(48 + pcm.len() as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEJUNK\x04\0\0\0testfmt \x10\0\0\0\x01\0\x01\0");
    wav.extend_from_slice(&24_000_u32.to_le_bytes());
    wav.extend_from_slice(&48_000_u32.to_le_bytes());
    wav.extend_from_slice(b"\x02\0\x10\0data");
    wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    wav.extend_from_slice(&pcm);
    let mut sink = AudioSink::new(AudioFormat::WavPcm16, MAX_SEGMENT_BYTES);
    sink.write(&wav).unwrap();
    let compacted = sink.into_mp3().unwrap();
    assert!(crate::pcm::mp3_duration_seconds(&compacted).unwrap() < 1.45);
    let original = normalize_audio(&AudioFormat::WavPcm16, &wav).unwrap();
    let mut sink = AudioSink::new(AudioFormat::Mp3, MAX_SEGMENT_BYTES);
    sink.write(&original).unwrap();
    assert_eq!(sink.into_mp3().unwrap(), original);
    wav.pop();
    let mut sink = AudioSink::new(AudioFormat::WavPcm16, MAX_SEGMENT_BYTES);
    sink.write(&wav).unwrap();
    assert!(sink.into_mp3().is_err());
}

#[test]
fn processing_profile_invalidates_both_segment_and_chapter_cache_keys() {
    let preferences = crate::tts_preferences::TtsPreferences::default();
    let identity = ResolvedIdentity {
        selection: SessionSelection::from_legacy(&preferences.primary).unwrap(),
        runtime_revision: "test".into(),
        artifacts: Default::default(),
        reusable: true,
    };
    let segment = cache_material("book", "text-v1", &identity, &AudioFormat::Mp3).unwrap();
    let legacy = serde_json::to_string(&(
        CONTRACT_VERSION,
        "book",
        "text-v1",
        &identity,
        &AudioFormat::Mp3,
    ))
    .unwrap();
    assert_ne!(segment, legacy);
    let chapter = request_cache_material("book", Some("pt-BR"), &preferences, &[]).unwrap();
    assert!(segment.contains(crate::speech_silence::PROFILE));
    assert!(chapter.contains(crate::speech_silence::PROFILE));
}

/// 0.5 s of speech-level tone, a gap of `gap_ms` of digital zero, 0.5 s of tone again.
fn gap_duration(level: crate::tts_preferences::SilenceTrim, gap_ms: usize) -> f64 {
    let rate = 24_000;
    let mut samples = vec![4_000; rate / 2];
    samples.extend(vec![0; rate * gap_ms / 1_000]);
    samples.extend(vec![4_000; rate / 2]);
    let mp3 = pcm_sink(&samples, rate as u32)
        .with_silence_trim(level)
        .into_mp3()
        .unwrap();
    crate::pcm::mp3_duration_seconds(&mp3).unwrap()
}

#[test]
fn off_keeps_every_silence_untouched() {
    use crate::tts_preferences::SilenceTrim::Off;
    let duration = gap_duration(Off, 2_000);
    assert!((2.95..3.1).contains(&duration), "duration: {duration}");
}

#[test]
fn light_turns_a_gap_over_600_ms_into_300_ms_and_keeps_shorter_ones() {
    use crate::tts_preferences::SilenceTrim::Light;
    assert!((1.25..1.45).contains(&gap_duration(Light, 2_000)));
    assert!((1.45..1.6).contains(&gap_duration(Light, 500)));
}

#[test]
fn medium_turns_a_gap_over_400_ms_into_200_ms() {
    use crate::tts_preferences::SilenceTrim::Medium;
    assert!((1.15..1.3).contains(&gap_duration(Medium, 500)));
    assert!((1.15..1.3).contains(&gap_duration(Medium, 2_000)));
    assert!((1.3..1.4).contains(&gap_duration(Medium, 300)));
}

#[test]
fn strong_turns_a_gap_over_250_ms_into_120_ms() {
    use crate::tts_preferences::SilenceTrim::Strong;
    assert!((1.1..1.2).contains(&gap_duration(Strong, 300)));
    assert!((1.1..1.2).contains(&gap_duration(Strong, 2_000)));
    assert!((1.15..1.25).contains(&gap_duration(Strong, 200)));
}

#[test]
fn every_level_has_its_own_cache_identity() {
    use crate::tts_preferences::{SilenceTrim, TtsPreferences};
    let material = |level| {
        let preferences = TtsPreferences {
            silence_trim: level,
            ..TtsPreferences::default()
        };
        request_cache_material("book", Some("en"), &preferences, &[]).unwrap()
    };
    let all = [
        material(SilenceTrim::Off),
        material(SilenceTrim::Light),
        material(SilenceTrim::Medium),
        material(SilenceTrim::Strong),
    ];
    for (i, a) in all.iter().enumerate() {
        for b in &all[i + 1..] {
            assert_ne!(a, b);
        }
    }
}
