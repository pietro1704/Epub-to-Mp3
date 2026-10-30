//! Structural pauses belong to generated audio, never to the reader's text axis.
use crate::{cache, tts_session::*};

pub(super) const PAUSE_MILLIS: u32 = 800;

pub(super) fn request_key(base: &str, heading_ends: &[usize]) -> String {
    if heading_ends.is_empty() {
        return base.to_owned();
    }
    cache::sha256_bytes(
        serde_json::to_string(&(base, "heading-pause-v1", PAUSE_MILLIS, heading_ends))
            .expect("heading pause identity")
            .as_bytes(),
    )
}

pub(super) fn follows_heading(segment: &SourceTextSegment, heading_ends: &[usize]) -> bool {
    let trailing = segment
        .source
        .chars()
        .rev()
        .take_while(|c| c.is_whitespace())
        .count();
    heading_ends
        .binary_search(&(segment.scalar_range.end - trailing))
        .is_ok()
}

pub(super) fn speech_identity(source: &str, spoken: &str, pause: bool) -> String {
    if pause {
        serde_json::to_string(&(source, spoken, "heading-pause-v1", PAUSE_MILLIS))
    } else {
        serde_json::to_string(&(source, spoken))
    }
    .expect("speech text identity")
}

pub(super) fn append(
    bytes: &mut Vec<u8>,
    pause: bool,
    context: &SynthesisContext<'_>,
) -> Result<(), TtsFailure> {
    context.check()?;
    if !pause {
        return Ok(());
    }
    // Native sessions normalize segments to 24 kHz MP3. The silence uses the
    // same encoder/rate and is retained in streamed and final chapter artifacts.
    let silence = encode_pcm_f32(&vec![0.0; 24_000 * PAUSE_MILLIS as usize / 1_000], 24_000)?;
    context.check()?;
    if bytes.len().saturating_add(silence.len()) > MAX_SEGMENT_BYTES {
        return Err(TtsFailure::new(
            FailureKind::InvalidAudio,
            "Heading pause exceeds segment limit",
        ));
    }
    bytes.extend(silence);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heading_pause_is_encoded_audio_and_ordinary_text_is_unchanged() {
        let context = SynthesisContext {
            language: "pt-BR",
            cancelled: &|| false,
            replaced: &|| false,
        };
        let original = encode_pcm_f32(&vec![0.1; 2_400], 24_000).unwrap();
        let mut ordinary = original.clone();
        append(&mut ordinary, false, &context).unwrap();
        assert_eq!(ordinary, original);
        let mut headed = original.clone();
        append(&mut headed, true, &context).unwrap();
        let added = crate::pcm::mp3_duration_seconds(&headed).unwrap()
            - crate::pcm::mp3_duration_seconds(&original).unwrap();
        assert!((0.8..0.95).contains(&added), "encoded pause: {added}");
        assert!(headed.starts_with(&original));
    }

    #[test]
    fn cancelled_or_replaced_pause_cannot_mutate_audio() {
        for replaced in [false, true] {
            let context = SynthesisContext {
                language: "pt-BR",
                cancelled: &|| !replaced,
                replaced: &|| replaced,
            };
            let mut bytes = vec![1, 2, 3];
            assert!(append(&mut bytes, true, &context).is_err());
            assert_eq!(bytes, [1, 2, 3]);
        }
    }

    #[test]
    fn heading_metadata_and_pause_policy_change_cache_identity() {
        assert_eq!(request_key("legacy", &[]), "legacy");
        assert_ne!(request_key("legacy", &[8]), request_key("legacy", &[9]));
        assert_ne!(request_key("legacy", &[8]), "legacy");
        assert_eq!(
            speech_identity("Title", "Title", false),
            serde_json::to_string(&("Title", "Title")).unwrap()
        );
        assert_ne!(
            speech_identity("Title", "Title", false),
            speech_identity("Title", "Title", true)
        );
    }

    #[test]
    fn trailing_boundary_whitespace_does_not_hide_the_heading() {
        let segment = SourceTextSegment {
            source: "Título  ".into(),
            byte_range: 0..9,
            scalar_range: 0..8,
        };
        assert!(follows_heading(&segment, &[6]));
        assert!(!follows_heading(&segment, &[8]));
    }
}

#[cfg(test)]
mod decoded_pause_tests {
    use super::*;

    #[test]
    fn generated_pause_decodes_to_silence() {
        use symphonia::core::{
            audio::SampleBuffer,
            io::{MediaSourceStream, MediaSourceStreamOptions},
            probe::Hint,
        };
        let context = SynthesisContext {
            language: "pt-BR",
            cancelled: &|| false,
            replaced: &|| false,
        };
        let mut bytes = Vec::new();
        append(&mut bytes, true, &context).unwrap();
        let stream = MediaSourceStream::new(
            Box::new(std::io::Cursor::new(bytes)),
            MediaSourceStreamOptions::default(),
        );
        let mut hint = Hint::new();
        hint.with_extension("mp3");
        let mut probed = symphonia::default::get_probe()
            .format(&hint, stream, &Default::default(), &Default::default())
            .unwrap();
        let track = probed.format.default_track().unwrap();
        let mut decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &Default::default())
            .unwrap();
        let mut samples = 0;
        while let Ok(packet) = probed.format.next_packet() {
            let audio = decoder.decode(&packet).unwrap();
            let mut decoded = SampleBuffer::<f32>::new(audio.capacity() as u64, *audio.spec());
            decoded.copy_interleaved_ref(audio);
            assert!(decoded.samples().iter().all(|sample| sample.abs() < 0.0001));
            samples += decoded.samples().len();
        }
        assert!(samples >= 19_200, "Decoded {samples} samples at 24 kHz");
    }
}
