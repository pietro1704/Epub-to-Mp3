//! Inline footnote narration: a spoken-text layer derived from a chapter's source text.
//!
//! The source text axis is never changed (clients highlight and seek on it). For narration a
//! second text is derived: every note reference is followed by the spoken note
//! ("Início da nota de rodapé N. … Fim da nota de rodapé N."), and the body of a note that sits
//! in the same document is left out where it appears (it is read at its reference instead).
//! `SpokenChapter` keeps a map from every spoken range back to the source text, so the audio
//! alignment can point at the note body while it is read and at the reference afterwards.
use super::NoteMark;
use crate::tts_preferences::FootnoteNarration;
use std::ops::Range;

/// Cache identity of the footnote narration policy: chapters with notes never reuse audio
/// made without it (chapters without notes narrate exactly as before and keep their audio).
pub const POLICY: &str = "narration-footnote-v1";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SpanKind {
    /// Source text read as written.
    Source,
    /// A spoken footnote; `number` is the number the markers say.
    Note { number: String },
}

/// A piece of spoken text and where it comes from in the source text (chapter coordinates).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    pub spoken: Range<usize>,
    /// Source text read by a `Source` span; for a note, the body in the chapter when it has
    /// one, otherwise the empty range at the reference.
    pub source: Range<usize>,
    pub kind: SpanKind,
}

/// What a range of spoken text corresponds to in the source text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Binding {
    /// The spoken text equals the source text starting at this scalar offset.
    Source { offset: usize },
    /// A spoken note: highlight `source` (the body, or the reference when the body is elsewhere).
    Note {
        number: String,
        source: Range<usize>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpokenChapter {
    pub text: String,
    pub paragraph_ends: Vec<usize>,
    pub heading_ends: Vec<usize>,
    /// Spoken offsets where a note begins (end of the text before it) and ends: each is a
    /// segment boundary followed by the note pause.
    pub note_edges: Vec<usize>,
    pub spans: Vec<Span>,
}

struct Piece {
    text: String,
    source: Range<usize>,
    kind: SpanKind,
    spoken: Range<usize>,
}

impl SpokenChapter {
    /// Derive the spoken layer for `text` (the chapter text from `text_offset` on). Returns
    /// `None` when narration is identical to the source text. `marks` use chapter coordinates.
    pub fn derive(
        text: &str,
        text_offset: usize,
        paragraph_ends: &[usize],
        heading_ends: &[usize],
        marks: &[NoteMark],
        mode: FootnoteNarration,
        language: Option<&str>,
    ) -> Option<Self> {
        let chars: Vec<char> = text.chars().collect();
        let length = chars.len();
        // Marks in slice coordinates. A reference before the slice was narrated already.
        let local = |value: usize| value.checked_sub(text_offset);
        let mut removals: Vec<Range<usize>> = Vec::new();
        let mut inserts: Vec<(usize, usize)> = Vec::new(); // (slice offset, mark index)
        for (index, mark) in marks.iter().enumerate() {
            if let Some(body) = &mark.body {
                if let Some(end) = local(body.end).filter(|end| *end > 0) {
                    let start = local(body.start).unwrap_or(0).min(length);
                    removals.push(start..end.min(length));
                }
            }
            if mode == FootnoteNarration::Inline && !mark.text.trim().is_empty() {
                if let Some(at) = local(mark.reference_end).filter(|at| *at <= length) {
                    inserts.push((at, index));
                }
            }
        }
        removals.retain(|range| range.start < range.end);
        removals.sort_by_key(|range| range.start);
        let mut merged: Vec<Range<usize>> = Vec::new();
        for range in removals {
            match merged.last_mut() {
                Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
                _ => merged.push(range),
            }
        }
        // A reference inside a removed body (a note citing a note) is not narrated.
        inserts.retain(|(at, _)| !merged.iter().any(|body| body.start < *at && *at < body.end));
        if merged.is_empty() && inserts.is_empty() {
            return None;
        }
        inserts.sort_by_key(|(at, index)| (*at, *index));

        let mut cuts: Vec<usize> = vec![0, length];
        cuts.extend(merged.iter().flat_map(|range| [range.start, range.end]));
        cuts.extend(inserts.iter().map(|(at, _)| *at));
        cuts.sort_unstable();
        cuts.dedup();

        let mut pieces: Vec<Piece> = Vec::new();
        let mut insert_cursor = 0;
        let mut push_notes_at = |position: usize, pieces: &mut Vec<Piece>| {
            while insert_cursor < inserts.len() && inserts[insert_cursor].0 == position {
                let index = inserts[insert_cursor].1;
                insert_cursor += 1;
                let mark = &marks[index];
                let number = spoken_number(mark.label.as_deref(), index);
                let body = mark.body.as_ref().and_then(|body| {
                    let start = body.start;
                    (body.end > start).then_some(start..body.end)
                });
                let reference = mark.reference_end;
                pieces.push(Piece {
                    text: spoken_note(language, &number, &mark.text),
                    source: body.unwrap_or(reference..reference),
                    kind: SpanKind::Note { number },
                    spoken: 0..0,
                });
            }
        };
        for window in cuts.windows(2) {
            let (start, end) = (window[0], window[1]);
            push_notes_at(start, &mut pieces);
            if merged
                .iter()
                .any(|body| body.start <= start && end <= body.end)
            {
                continue;
            }
            let mut from = start;
            let mut to = end;
            while from < to && chars[from].is_whitespace() {
                from += 1;
            }
            while to > from && chars[to - 1].is_whitespace() {
                to -= 1;
            }
            if from < to {
                pieces.push(Piece {
                    text: chars[from..to].iter().collect(),
                    source: from + text_offset..to + text_offset,
                    kind: SpanKind::Source,
                    spoken: 0..0,
                });
            }
        }
        push_notes_at(length, &mut pieces);
        if pieces.is_empty() {
            return None;
        }

        let mut spoken = String::new();
        let mut cursor = 0;
        for piece in &mut pieces {
            if cursor > 0 {
                spoken.push(' ');
                cursor += 1;
            }
            let width = piece.text.chars().count();
            piece.spoken = cursor..cursor + width;
            spoken.push_str(&piece.text);
            cursor += width;
        }

        // Source offsets (slice coordinates) -> spoken offsets: the end of the last piece the
        // source offset has reached; a note placed exactly at the offset belongs before it.
        let map_end = |end: usize| -> Option<usize> {
            let mut mapped = None;
            for piece in &pieces {
                match piece.kind {
                    SpanKind::Source if piece.source.start < end + text_offset => {
                        let reached = (end + text_offset).min(piece.source.end);
                        mapped = Some(piece.spoken.start + (reached - piece.source.start));
                    }
                    SpanKind::Note { .. }
                        if piece.source.is_empty() && piece.source.start == end + text_offset =>
                    {
                        mapped = Some(piece.spoken.end);
                    }
                    _ => {}
                }
            }
            mapped
        };
        let translate = |ends: &[usize]| -> Vec<usize> {
            let mut result: Vec<usize> = ends
                .iter()
                .filter_map(|end| map_end(*end))
                .filter(|end| *end > 0)
                .collect();
            result.sort_unstable();
            result.dedup();
            result
        };
        let mut note_edges = Vec::new();
        for (index, piece) in pieces.iter().enumerate() {
            if matches!(piece.kind, SpanKind::Note { .. }) {
                if index > 0 {
                    note_edges.push(pieces[index - 1].spoken.end);
                }
                note_edges.push(piece.spoken.end);
            }
        }
        note_edges.sort_unstable();
        note_edges.dedup();
        Some(Self {
            paragraph_ends: translate(paragraph_ends),
            heading_ends: translate(heading_ends),
            note_edges,
            spans: pieces
                .iter()
                .map(|piece| Span {
                    spoken: piece.spoken.clone(),
                    source: piece.source.clone(),
                    kind: piece.kind.clone(),
                })
                .collect(),
            text: spoken,
        })
    }

    /// Map a spoken range (one synthesized segment) back to the source text.
    pub fn binding(&self, spoken: Range<usize>) -> Option<Binding> {
        let span = self
            .spans
            .iter()
            .find(|span| span.spoken.start <= spoken.start && spoken.start < span.spoken.end)?;
        if spoken.end > span.spoken.end {
            return None;
        }
        Some(match &span.kind {
            SpanKind::Source => Binding::Source {
                offset: span.source.start + (spoken.start - span.spoken.start),
            },
            SpanKind::Note { number } => Binding::Note {
                number: number.clone(),
                source: span.source.clone(),
            },
        })
    }
}

/// The number the markers say: the reference label when it is a plain number ("1", "[1]"),
/// otherwise the note's position in the chapter ("*", "†").
fn spoken_number(label: Option<&str>, index: usize) -> String {
    let digits = label
        .map(|label| label.trim_matches(|c: char| !c.is_alphanumeric()))
        .filter(|label| !label.is_empty() && label.chars().all(|c| c.is_ascii_digit()));
    digits.map_or_else(|| (index + 1).to_string(), str::to_owned)
}

/// "Início da nota de rodapé N. {body} Fim da nota de rodapé N." in the chapter's language.
fn spoken_note(language: Option<&str>, number: &str, body: &str) -> String {
    let tag = language.unwrap_or("").to_ascii_lowercase();
    let (start, end) = if tag.starts_with("pt") {
        (
            format!("Início da nota de rodapé {number}."),
            format!("Fim da nota de rodapé {number}."),
        )
    } else if tag.starts_with("es") {
        (
            format!("Nota al pie {number}."),
            format!("Fin de la nota al pie {number}."),
        )
    } else {
        (
            format!("Footnote {number}."),
            format!("End of footnote {number}."),
        )
    };
    let body = body.trim();
    let closed = body.ends_with(['.', '!', '?', '…', ':', ';', '"', '”', ')']);
    if closed {
        format!("{start} {body} {end}")
    } else {
        format!("{start} {body}. {end}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mark(reference_end: usize, label: &str, text: &str, body: Option<Range<usize>>) -> NoteMark {
        NoteMark {
            reference_end,
            label: Some(label.into()),
            text: text.into(),
            body,
        }
    }

    // "Texto antes 1 e depois. Corpo da nota." — the reference ends at 13, the body is 24..38.
    const SAME_DOCUMENT: &str = "Texto antes 1 e depois. Corpo da nota.";

    fn derive(marks: &[NoteMark], mode: FootnoteNarration) -> SpokenChapter {
        SpokenChapter::derive(SAME_DOCUMENT, 0, &[23, 38], &[], marks, mode, Some("pt-BR"))
            .expect("a chapter with a note is derived")
    }

    #[test]
    fn the_note_is_read_at_its_reference_and_not_again_at_the_chapter_end() {
        let spoken = derive(
            &[mark(13, "1", "Corpo da nota.", Some(24..38))],
            FootnoteNarration::Inline,
        );
        assert_eq!(
            spoken.text,
            "Texto antes 1 Início da nota de rodapé 1. Corpo da nota. Fim da nota de rodapé 1. e depois."
        );
    }

    #[test]
    fn the_spoken_note_is_bounded_by_segment_edges_and_keeps_structure_on_the_spoken_axis() {
        let spoken = derive(
            &[mark(13, "1", "Corpo da nota.", Some(24..38))],
            FootnoteNarration::Inline,
        );
        let before = "Texto antes 1".chars().count();
        let after =
            "Texto antes 1 Início da nota de rodapé 1. Corpo da nota. Fim da nota de rodapé 1."
                .chars()
                .count();
        assert_eq!(spoken.note_edges, vec![before, after]);
        // The paragraph that held the reference still ends after "depois."
        assert_eq!(
            spoken.paragraph_ends,
            vec![spoken.text.chars().count()],
            "the source paragraph ends map onto the spoken axis: {:?}",
            spoken.paragraph_ends
        );
    }

    #[test]
    fn spoken_ranges_map_back_to_the_source_and_the_note_maps_to_its_body() {
        let spoken = derive(
            &[mark(13, "1", "Corpo da nota.", Some(24..38))],
            FootnoteNarration::Inline,
        );
        // "Texto antes 1" is source text from 0; "e depois." resumes at source 14.
        assert_eq!(spoken.binding(0..13), Some(Binding::Source { offset: 0 }));
        let note_start = "Texto antes 1 ".chars().count();
        let note_end = note_start
            + "Início da nota de rodapé 1. Corpo da nota. Fim da nota de rodapé 1."
                .chars()
                .count();
        assert_eq!(
            spoken.binding(note_start + 2..note_start + 8),
            Some(Binding::Note {
                number: "1".into(),
                source: 24..38
            })
        );
        let resumed = note_end + 1;
        assert_eq!(
            spoken.binding(resumed..resumed + 2),
            Some(Binding::Source { offset: 14 })
        );
    }

    #[test]
    fn a_note_whose_body_is_in_another_document_maps_to_its_reference() {
        let text = "Texto antes 1 e depois.";
        let spoken = SpokenChapter::derive(
            text,
            0,
            &[23],
            &[],
            &[mark(13, "1", "Nota externa.", None)],
            FootnoteNarration::Inline,
            Some("en"),
        )
        .unwrap();
        assert_eq!(
            spoken.text,
            "Texto antes 1 Footnote 1. Nota externa. End of footnote 1. e depois."
        );
        let note_start = "Texto antes 1 ".chars().count();
        assert_eq!(
            spoken.binding(note_start..note_start + 4),
            Some(Binding::Note {
                number: "1".into(),
                source: 13..13
            })
        );
    }

    #[test]
    fn skip_leaves_the_bodies_out_and_reads_no_note() {
        let spoken = derive(
            &[mark(13, "1", "Corpo da nota.", Some(24..38))],
            FootnoteNarration::Skip,
        );
        assert_eq!(spoken.text, "Texto antes 1 e depois.");
        assert!(spoken.note_edges.is_empty());
    }

    #[test]
    fn chapters_without_notes_are_not_derived() {
        for mode in [FootnoteNarration::Inline, FootnoteNarration::Skip] {
            assert_eq!(
                SpokenChapter::derive("Sem notas.", 0, &[10], &[], &[], mode, None),
                None
            );
        }
    }

    #[test]
    fn markers_are_localized_and_unlabelled_notes_are_numbered_in_order() {
        let text = "Um* dois†.";
        let marks = [
            mark(3, "*", "Primeira.", None),
            mark(10, "†", "Segunda.", None),
        ];
        let es = SpokenChapter::derive(
            text,
            0,
            &[10],
            &[],
            &marks,
            FootnoteNarration::Inline,
            Some("es-ES"),
        )
        .unwrap();
        assert!(es
            .text
            .contains("Nota al pie 1. Primeira. Fin de la nota al pie 1."));
        assert!(es
            .text
            .contains("Nota al pie 2. Segunda. Fin de la nota al pie 2."));
    }

    #[test]
    fn resuming_after_the_reference_still_drops_the_body_but_does_not_repeat_the_note() {
        // Listening resumed at scalar 15: the slice starts inside "e depois." and the
        // reference (13) was already narrated, the body (24..38) is still ahead.
        let text: String = SAME_DOCUMENT.chars().skip(15).collect();
        let spoken = SpokenChapter::derive(
            &text,
            15,
            &[8, 23],
            &[],
            &[mark(13, "1", "Corpo da nota.", Some(24..38))],
            FootnoteNarration::Inline,
            Some("pt-BR"),
        )
        .unwrap();
        assert_eq!(spoken.text, "depois.");
        // "depois." starts at source scalar 16 (scalar 15 is the space the slice begins with).
        assert_eq!(spoken.binding(0..7), Some(Binding::Source { offset: 16 }));
    }
}
