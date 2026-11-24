//! Structural pauses belong to generated audio, never to the reader's text axis.
//!
//! A pause is an explicit segment of digital silence appended to the audio of the segment
//! that ends a structural unit. Sentences keep the voice's own pacing; paragraphs, headings
//! and the end of a chapter get a measured pause. The policy (and its constants) is part of
//! the cache identity (`narration-pause-v1`) so audio made without it is never reused.
use crate::{cache, tts_session::*};

/// Silence after a heading, on top of the voice's own trailing silence.
pub(super) const HEADING_MILLIS: u32 = 800;
/// Total gap wanted between two paragraphs (measured: Piper 0.14 s and the system voice
/// 0.30 s natural gap, so the explicit silence is the difference).
pub(super) const PARAGRAPH_TOTAL_PIPER_MILLIS: u32 = 450;
pub(super) const PARAGRAPH_TOTAL_SYSTEM_MILLIS: u32 = 550;
/// Total silence wanted at the end of a chapter.
pub(super) const CHAPTER_END_TOTAL_MILLIS: u32 = 1_000;
/// Total silence around a narrated footnote (before its start marker and after its end marker).
pub(super) const NOTE_TOTAL_MILLIS: u32 = 500;
/// Natural gap the voices leave on their own, measured with `ffmpeg silencedetect`.
const NATURAL_PIPER_MILLIS: u32 = 140;
const NATURAL_SYSTEM_MILLIS: u32 = 300;
const POLICY: &str = "narration-pause-v1";

/// The structural boundary a segment ends on, strongest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Boundary {
    None,
    Paragraph,
    Heading,
    ChapterEnd,
    /// Start or end of a narrated footnote.
    Note,
    /// A narrated footnote edge that is also the end of a paragraph.
    NoteParagraph,
}

/// Where the structural units of one chapter text end (scalar offsets).
#[derive(Debug, Clone, Copy)]
pub(super) struct Structure<'a> {
    pub heading_ends: &'a [usize],
    pub paragraph_ends: &'a [usize],
    /// Spoken offsets where a narrated footnote starts or ends (empty without notes).
    pub note_edges: &'a [usize],
    /// Scalar offset where the last content (non-whitespace) of the chapter text ends.
    pub chapter_end: usize,
}

impl<'a> Structure<'a> {
    pub fn new(text: &str, heading_ends: &'a [usize], paragraph_ends: &'a [usize]) -> Self {
        Self {
            heading_ends,
            paragraph_ends,
            note_edges: &[],
            chapter_end: text.trim_end().chars().count(),
        }
    }

    pub fn with_note_edges(mut self, note_edges: &'a [usize]) -> Self {
        self.note_edges = note_edges;
        self
    }
}

pub(super) fn request_key(base: &str, structure: &Structure<'_>) -> String {
    let pauses = (
        base,
        POLICY,
        HEADING_MILLIS,
        PARAGRAPH_TOTAL_PIPER_MILLIS,
        PARAGRAPH_TOTAL_SYSTEM_MILLIS,
        CHAPTER_END_TOTAL_MILLIS,
        structure.heading_ends,
    );
    // Chapters without narrated footnotes keep their previous identity (and their audio).
    let identity = if structure.note_edges.is_empty() {
        serde_json::to_string(&pauses)
    } else {
        serde_json::to_string(&(
            pauses,
            crate::epub::footnote_narration::POLICY,
            NOTE_TOTAL_MILLIS,
            structure.note_edges,
        ))
    };
    cache::sha256_bytes(identity.expect("narration pause identity").as_bytes())
}

/// The strongest boundary the segment ends on (trailing whitespace is not content).
pub(super) fn boundary_after(segment: &SourceTextSegment, structure: &Structure<'_>) -> Boundary {
    let trailing = segment
        .source
        .chars()
        .rev()
        .take_while(|c| c.is_whitespace())
        .count();
    let end = segment.scalar_range.end - trailing;
    if end >= structure.chapter_end {
        Boundary::ChapterEnd
    } else if structure.heading_ends.binary_search(&end).is_ok() {
        Boundary::Heading
    } else {
        let paragraph = structure.paragraph_ends.binary_search(&end).is_ok();
        let note = structure.note_edges.binary_search(&end).is_ok();
        match (paragraph, note) {
            (true, true) => Boundary::NoteParagraph,
            (true, false) => Boundary::Paragraph,
            (false, true) => Boundary::Note,
            (false, false) => Boundary::None,
        }
    }
}

/// Explicit silence to append after a segment rendered by `engine`.
pub(super) fn pause_millis(boundary: Boundary, engine: &str) -> u32 {
    let system = engine == "system";
    let natural = if system {
        NATURAL_SYSTEM_MILLIS
    } else {
        NATURAL_PIPER_MILLIS
    };
    match boundary {
        Boundary::None => 0,
        Boundary::Heading => HEADING_MILLIS,
        Boundary::Paragraph => {
            let total = if system {
                PARAGRAPH_TOTAL_SYSTEM_MILLIS
            } else {
                PARAGRAPH_TOTAL_PIPER_MILLIS
            };
            total - natural
        }
        Boundary::ChapterEnd => CHAPTER_END_TOTAL_MILLIS - natural,
        Boundary::Note => NOTE_TOTAL_MILLIS - natural,
        Boundary::NoteParagraph => {
            let paragraph = if system {
                PARAGRAPH_TOTAL_SYSTEM_MILLIS
            } else {
                PARAGRAPH_TOTAL_PIPER_MILLIS
            };
            paragraph.max(NOTE_TOTAL_MILLIS) - natural
        }
    }
}

pub(super) fn speech_identity(source: &str, spoken: &str, pause_millis: u32) -> String {
    if pause_millis > 0 {
        serde_json::to_string(&(source, spoken, POLICY, pause_millis))
    } else {
        serde_json::to_string(&(source, spoken))
    }
    .expect("speech text identity")
}

pub(super) fn append(
    bytes: &mut Vec<u8>,
    pause_millis: u32,
    context: &SynthesisContext<'_>,
) -> Result<(), TtsFailure> {
    context.check()?;
    if pause_millis == 0 {
        return Ok(());
    }
    // Native sessions normalize segments to 24 kHz MP3. The silence uses the
    // same encoder/rate and is retained in streamed and final chapter artifacts.
    let silence = encode_pcm_f32(&vec![0.0; 24_000 * pause_millis as usize / 1_000], 24_000)?;
    context.check()?;
    if bytes.len().saturating_add(silence.len()) > MAX_SEGMENT_BYTES {
        return Err(TtsFailure::new(
            FailureKind::InvalidAudio,
            "Narration pause exceeds segment limit",
        ));
    }
    // One stream, one aggregate header: the silence is part of the segment's declared length.
    *bytes = crate::audio::join_mp3_segments(&[bytes.as_slice(), &silence]).map_err(|error| {
        TtsFailure::new(
            FailureKind::InvalidAudio,
            format!("Narration pause could not join the segment: {error}"),
        )
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segment(source: &str, start: usize) -> SourceTextSegment {
        let scalars = source.chars().count();
        SourceTextSegment {
            source: source.into(),
            byte_range: start..start + source.len(),
            scalar_range: start..start + scalars,
        }
    }

    fn context<'a>() -> SynthesisContext<'a> {
        SynthesisContext {
            language: "pt-BR",
            cancelled: &|| false,
            replaced: &|| false,
        }
    }

    #[test]
    fn a_paused_segment_is_one_stream_whose_header_counts_every_frame() {
        // A streamed chunk is played on its own: its Info/Xing header must declare the
        // speech AND the silence, or Apple decoders report a shorter length than they decode.
        let directory = tempfile::tempdir().unwrap();
        let speech = encode_pcm_f32(&vec![0.1; 12_000], 24_000).unwrap();
        let alone = directory.path().join("speech.mp3");
        std::fs::write(&alone, &speech).unwrap();
        let mut paused = speech.clone();
        append(&mut paused, 310, &context()).unwrap();
        let path = directory.path().join("paused.mp3");
        std::fs::write(&path, &paused).unwrap();
        assert!(
            !crate::audio::mp3_needs_finalization(&path).unwrap(),
            "the header must declare the whole segment, not only the speech"
        );
        let expected = crate::audio::probe_duration(&alone).unwrap() + 0.310;
        let declared = crate::audio::probe_duration(&path).unwrap();
        assert!(
            (declared - expected).abs() < 0.06,
            "declared {declared} s, speech + pause {expected} s"
        );
        crate::audio::validate_audio(&path, 1).unwrap();
    }

    #[test]
    fn pause_is_encoded_audio_and_ordinary_text_is_unchanged() {
        let original = encode_pcm_f32(&vec![0.1; 2_400], 24_000).unwrap();
        let mut ordinary = original.clone();
        append(&mut ordinary, 0, &context()).unwrap();
        assert_eq!(ordinary, original);
        let mut headed = original.clone();
        append(&mut headed, HEADING_MILLIS, &context()).unwrap();
        let added = crate::pcm::mp3_duration_seconds(&headed).unwrap()
            - crate::pcm::mp3_duration_seconds(&original).unwrap();
        assert!((0.8..0.95).contains(&added), "encoded pause: {added}");
        // The aggregate header replaces the first frame; the speech frames stay untouched.
        let header = rusty_mp3::header::FrameHeader::parse(original[..4].try_into().unwrap())
            .unwrap()
            .frame_size();
        assert!(headed[header..].starts_with(&original[header..]));
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
            assert!(append(&mut bytes, HEADING_MILLIS, &context).is_err());
            assert_eq!(bytes, [1, 2, 3]);
        }
    }

    #[test]
    fn paragraph_headings_and_chapter_end_get_their_own_pause_and_sentences_none() {
        // "Title\nOne. Two.\nThree." = heading 0..5, paragraphs 0..5, 6..15, 16..22
        let text = "Title\nOne. Two.\nThree.\n";
        let structure = Structure::new(text, &[5], &[5, 15, 22]);
        assert_eq!(structure.chapter_end, 22);
        let title = segment("Title", 0);
        let first = segment("\nOne. Two.", 5);
        let sentence = segment("\nOne.", 5);
        let last = segment("\nThree.\n", 15);
        assert_eq!(boundary_after(&title, &structure), Boundary::Heading);
        assert_eq!(boundary_after(&first, &structure), Boundary::Paragraph);
        assert_eq!(boundary_after(&sentence, &structure), Boundary::None);
        assert_eq!(boundary_after(&last, &structure), Boundary::ChapterEnd);
    }

    #[test]
    fn pause_lengths_follow_the_approved_policy_per_engine() {
        // Totals: paragraph 0.45 s (Piper) / 0.55 s (system); chapter end 1.0 s; heading 0.8 s.
        assert_eq!(pause_millis(Boundary::None, "piper"), 0);
        assert_eq!(pause_millis(Boundary::Paragraph, "piper"), 450 - 140);
        assert_eq!(pause_millis(Boundary::Paragraph, "system"), 550 - 300);
        assert_eq!(pause_millis(Boundary::ChapterEnd, "piper"), 1_000 - 140);
        assert_eq!(pause_millis(Boundary::ChapterEnd, "system"), 1_000 - 300);
        assert_eq!(pause_millis(Boundary::Heading, "piper"), 800);
        assert_eq!(pause_millis(Boundary::Heading, "system"), 800);
        // A narrated footnote is set off by 0.5 s in total on both sides; a paragraph end that
        // is also a note edge keeps the larger of the two totals.
        assert_eq!(pause_millis(Boundary::Note, "piper"), 500 - 140);
        assert_eq!(pause_millis(Boundary::Note, "system"), 500 - 300);
        assert_eq!(pause_millis(Boundary::NoteParagraph, "piper"), 500 - 140);
        assert_eq!(pause_millis(Boundary::NoteParagraph, "system"), 550 - 300);
    }

    #[test]
    fn note_edges_are_boundaries_and_change_identity_only_when_present() {
        let text = "Texto 1 Nota. e depois.";
        let plain = Structure::new(text, &[], &[23]);
        let edges = [7, 13];
        let noted = Structure::new(text, &[], &[23]).with_note_edges(&edges);
        assert_eq!(
            request_key("k", &plain),
            request_key("k", &Structure::new(text, &[], &[23]).with_note_edges(&[]))
        );
        assert_ne!(request_key("k", &plain), request_key("k", &noted));
        let before = segment("Texto 1", 0);
        let inside = segment("Texto 1 Nota.", 0);
        assert_eq!(boundary_after(&before, &noted), Boundary::Note);
        assert_eq!(boundary_after(&inside, &noted), Boundary::Note);
        assert_eq!(boundary_after(&before, &plain), Boundary::None);
    }

    #[test]
    fn the_pause_policy_and_structure_change_cache_identity() {
        let text = "Title body";
        let plain = Structure::new(text, &[], &[10]);
        let headed = Structure::new(text, &[5], &[5, 10]);
        assert_ne!(
            request_key("legacy", &plain),
            "legacy",
            "old audio has no pauses"
        );
        assert_ne!(
            request_key("legacy", &plain),
            request_key("legacy", &headed)
        );
        assert_eq!(
            speech_identity("Title", "Title", 0),
            serde_json::to_string(&("Title", "Title")).unwrap()
        );
        assert_ne!(
            speech_identity("Title", "Title", 0),
            speech_identity("Title", "Title", 800)
        );
        assert_ne!(
            speech_identity("Title", "Title", 310),
            speech_identity("Title", "Title", 250)
        );
    }

    #[test]
    fn trailing_boundary_whitespace_does_not_hide_the_boundary() {
        let structure = Structure::new("Título  corpo", &[6], &[6, 13]);
        assert_eq!(
            boundary_after(&segment("Título  ", 0), &structure),
            Boundary::Heading
        );
        assert_eq!(
            boundary_after(&segment("Título", 0), &structure),
            Boundary::Heading
        );
        assert_eq!(
            boundary_after(&segment("Título  c", 0), &structure),
            Boundary::None
        );
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
        append(&mut bytes, HEADING_MILLIS, &context).unwrap();
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
