//! Source-preserving Unicode segmentation shared by native and browser sessions.
use super::{FailureKind, TtsFailure};
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;

pub(crate) const TEXT_PLANNER_PROFILE: &str = "text-v2-sentence-paragraph-grapheme";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SourceTextSegment {
    pub source: String,
    pub byte_range: Range<usize>,
    pub scalar_range: Range<usize>,
}
impl SourceTextSegment {
    pub fn speech(&self) -> &str {
        self.source.trim()
    }
    pub fn relative_paragraph_ends(&self, paragraph_ends: &[usize]) -> Vec<usize> {
        paragraph_ends
            .iter()
            .copied()
            .filter(|end| *end > self.scalar_range.start && *end <= self.scalar_range.end)
            .map(|end| end - self.scalar_range.start)
            .collect()
    }
    pub fn rebase(&mut self, parent: &Self) {
        self.byte_range = self.byte_range.start + parent.byte_range.start
            ..self.byte_range.end + parent.byte_range.start;
        self.scalar_range = self.scalar_range.start + parent.scalar_range.start
            ..self.scalar_range.end + parent.scalar_range.start;
    }
}

pub fn segment_text(
    text: &str,
    initial: usize,
    subsequent: usize,
) -> Result<Vec<String>, TtsFailure> {
    segment_text_protecting(text, initial, subsequent, &[])
}

pub(crate) fn segment_text_protecting(
    text: &str,
    initial: usize,
    subsequent: usize,
    protected: &[(usize, usize)],
) -> Result<Vec<String>, TtsFailure> {
    Ok(
        plan_text_protecting(text, initial, subsequent, protected, &[])?
            .into_iter()
            .map(|segment| segment.speech().to_owned())
            .collect(),
    )
}

fn invalid(message: &str) -> TtsFailure {
    TtsFailure::new(FailureKind::InvalidSelection, message)
}

pub(crate) fn plan_text_protecting(
    text: &str,
    initial: usize,
    subsequent: usize,
    protected: &[(usize, usize)],
    paragraph_ends: &[usize],
) -> Result<Vec<SourceTextSegment>, TtsFailure> {
    plan_text_with_headings(text, initial, subsequent, protected, paragraph_ends, &[])
}

pub(crate) fn plan_text_with_headings(
    text: &str,
    initial: usize,
    subsequent: usize,
    protected: &[(usize, usize)],
    paragraph_ends: &[usize],
    heading_ends: &[usize],
) -> Result<Vec<SourceTextSegment>, TtsFailure> {
    if initial == 0 || subsequent == 0 {
        return Err(invalid("Text capacities must be nonzero"));
    }
    let total_scalars = text.chars().count();
    if paragraph_ends
        .iter()
        .any(|end| *end == 0 || *end > total_scalars)
        || paragraph_ends.windows(2).any(|pair| pair[0] >= pair[1])
    {
        return Err(invalid(
            "Paragraph ends must be ordered canonical scalar offsets",
        ));
    }
    if protected.iter().any(|(start, end)| {
        start >= end
            || *end > text.len()
            || !text.is_char_boundary(*start)
            || !text.is_char_boundary(*end)
    }) || protected.windows(2).any(|pair| pair[0].1 > pair[1].0)
    {
        return Err(invalid(
            "Protected terms require ordered valid UTF-8 ranges",
        ));
    }
    let protected = grapheme_protected_ranges(text, protected);
    let mut requested = paragraph_ends.iter().peekable();
    let mut paragraphs = Vec::new();
    for (scalar, (byte, _)) in text
        .char_indices()
        .chain(std::iter::once((text.len(), '\0')))
        .enumerate()
    {
        if requested.peek().is_some_and(|end| **end == scalar) {
            paragraphs.push(byte);
            requested.next();
        }
    }
    if heading_ends
        .iter()
        .any(|end| *end == 0 || *end > total_scalars)
        || heading_ends.windows(2).any(|pair| pair[0] >= pair[1])
    {
        return Err(invalid(
            "Heading ends must be ordered canonical scalar offsets",
        ));
    }
    let heading_bytes: Vec<_> = text
        .char_indices()
        .map(|(byte, _)| byte)
        .chain(std::iter::once(text.len()))
        .enumerate()
        .filter_map(|(scalar, byte)| heading_ends.binary_search(&scalar).is_ok().then_some(byte))
        .collect();
    let mut result = Vec::new();

    let mut cursor = 0;
    let mut scalar_cursor = 0;
    while cursor < text.len() {
        let pending = &text[cursor..];
        if pending.trim().is_empty() {
            if let Some(last) = result.last_mut() {
                let last: &mut SourceTextSegment = last;
                last.source.push_str(pending);
                last.byte_range.end = text.len();
                last.scalar_range.end = total_scalars;
            }
            break;
        }
        let content_start = cursor
            + pending
                .grapheme_indices(true)
                .find(|(_, grapheme)| !grapheme.chars().all(char::is_whitespace))
                .map(|(offset, _)| offset)
                .unwrap_or(pending.len());
        let content = &text[content_start..];
        let limit = if result.is_empty() {
            initial
        } else {
            subsequent
        };
        let mut used = 0;
        let mut ceiling = 0;
        for (byte, grapheme) in content.grapheme_indices(true) {
            let count = grapheme.chars().count();
            if used + count > limit {
                break;
            }
            used += count;
            ceiling = byte + grapheme.len();
        }
        if ceiling == 0 {
            return Err(invalid("A grapheme exceeds the synthesis text capacity"));
        }
        let mut boundary = if ceiling == content.len() {
            text.len()
        } else {
            let prefix = &content[..ceiling];
            let sentences = sentence_ends(content, ceiling);
            let paragraph = paragraphs
                .iter()
                .copied()
                .filter(|end| *end > content_start && *end <= content_start + ceiling)
                .collect::<Vec<_>>();
            let near = |end: usize| text[content_start..end].chars().count() >= used / 2;
            paragraph
                .iter()
                .copied()
                .rev()
                .find(|end| near(*end))
                .or_else(|| {
                    sentences
                        .iter()
                        .map(|end| content_start + end)
                        .rev()
                        .find(|end| near(*end))
                })
                .or_else(|| {
                    paragraph
                        .last()
                        .copied()
                        .into_iter()
                        .chain(sentences.last().map(|end| content_start + end))
                        .max()
                })
                .or_else(|| clause_end(prefix).map(|end| content_start + end))
                .or_else(|| {
                    prefix
                        .char_indices()
                        .rev()
                        .find(|(_, character)| character.is_whitespace())
                        .map(|(end, _)| content_start + end)
                })
                .unwrap_or(content_start + ceiling)
        };
        // A title remains a complete source span even when the provider could fit
        // its following paragraph. Protected pronunciation ranges still win.
        if let Some(end) = heading_bytes
            .iter()
            .copied()
            .find(|end| *end > content_start && *end <= boundary)
        {
            boundary = end;
        }
        if let Some((start, end)) = protected
            .iter()
            .find(|(start, end)| *start < boundary && *end > boundary)
        {
            boundary = if *start > content_start { *start } else { *end };
        }
        // Protected ranges are scalar based; extend their edge to a whole grapheme.
        if boundary < text.len() {
            if let Some((start, grapheme)) = text[content_start..]
                .grapheme_indices(true)
                .find(|(start, grapheme)| content_start + start + grapheme.len() >= boundary)
            {
                if content_start + start < boundary {
                    boundary = content_start + start + grapheme.len();
                }
            }
        }
        let whitespace = text[boundary..]
            .graphemes(true)
            .take_while(|grapheme| grapheme.chars().all(char::is_whitespace))
            .map(str::len)
            .sum::<usize>();
        boundary += whitespace;
        if boundary <= cursor {
            return Err(invalid("Text planner did not advance"));
        }
        let source = &text[cursor..boundary];
        let scalar_end = scalar_cursor + source.chars().count();
        result.push(SourceTextSegment {
            source: source.to_owned(),
            byte_range: cursor..boundary,
            scalar_range: scalar_cursor..scalar_end,
        });
        cursor = boundary;
        scalar_cursor = scalar_end;
    }
    Ok(result)
}

fn grapheme_protected_ranges(text: &str, ranges: &[(usize, usize)]) -> Vec<(usize, usize)> {
    if ranges.is_empty() {
        return Vec::new();
    }
    let mut ranges = ranges.to_vec();
    let mut active = 0;
    for (start, grapheme) in text.grapheme_indices(true) {
        let end = start + grapheme.len();
        while active < ranges.len() && ranges[active].1 <= start {
            active += 1;
        }
        let mut index = active;
        while index < ranges.len() && ranges[index].0 < end {
            if ranges[index].1 > start {
                ranges[index].0 = ranges[index].0.min(start);
                ranges[index].1 = ranges[index].1.max(end);
            }
            index += 1;
        }
    }
    let mut merged: Vec<(usize, usize)> = Vec::new();
    for (start, end) in ranges {
        if let Some(previous) = merged.last_mut().filter(|previous| previous.1 > start) {
            previous.1 = previous.1.max(end);
        } else {
            merged.push((start, end));
        }
    }
    merged
}

fn sentence_ends(text: &str, ceiling: usize) -> Vec<usize> {
    text[..ceiling]
        .split_sentence_bound_indices()
        .filter_map(|(start, sentence)| {
            let trimmed = sentence.trim_end();
            let end = start + trimmed.len();
            let terminal = trimmed.trim_end_matches(['"', '\'', '”', '’', ')', ']', '»']);
            let punctuation = terminal.chars().next_back()?;
            if !matches!(punctuation, '.' | '?' | '!' | '…') {
                return None;
            }
            let next = text[end..].chars().next();
            if next.is_some_and(|character| {
                matches!(
                    character,
                    '.' | '!' | '?' | '”' | '’' | ')' | ']' | '»' | '"'
                )
            }) {
                return None;
            }
            if punctuation == '.' {
                if terminal
                    .chars()
                    .rev()
                    .nth(1)
                    .is_some_and(|character| character.is_ascii_digit())
                    && next.is_some_and(|character| character.is_ascii_digit())
                {
                    return None;
                }
                let token = terminal
                    .trim_end_matches('.')
                    .rsplit(|character: char| !character.is_alphabetic())
                    .next()
                    .unwrap_or("")
                    .to_lowercase();
                if token.chars().count() == 1
                    || [
                        "sr", "sra", "srta", "dr", "dra", "prof", "profa", "etc", "ex", "pág",
                        "págs", "av", "art", "arts", "cap", "caps", "fig", "figs", "vol", "núm",
                        "vs",
                    ]
                    .contains(&token.as_str())
                {
                    return None;
                }
            }
            Some(end)
        })
        .collect()
}

fn clause_end(prefix: &str) -> Option<usize> {
    prefix
        .char_indices()
        .rev()
        .find(|(byte, character)| {
            matches!(character, ',' | ';' | ':')
                && prefix[byte + character.len_utf8()..]
                    .chars()
                    .next()
                    .is_none_or(char::is_whitespace)
        })
        .map(|(byte, character)| byte + character.len_utf8())
}

#[cfg(test)]
#[path = "text_tests.rs"]
mod tests;

#[cfg(test)]
mod heading_tests {
    use super::*;

    #[test]
    fn heading_ends_force_a_separate_source_preserving_segment() {
        let text = "Água clara Body follows without a title period.";
        let segments = plan_text_with_headings(text, 180, 800, &[], &[10, 47], &[10]).unwrap();
        assert_eq!(segments[0].speech(), "Água clara");
        assert_eq!(
            segments
                .iter()
                .map(|s| s.source.as_str())
                .collect::<String>(),
            text
        );
        assert_eq!(segments[1].scalar_range.start, 11);
    }

    #[test]
    fn invalid_heading_offsets_fail_and_protected_pronunciation_is_not_split() {
        for ends in [vec![0], vec![99], vec![3, 2]] {
            assert!(plan_text_with_headings("Title body", 180, 800, &[], &[], &ends).is_err());
        }
        let segments =
            plan_text_with_headings("Title body", 180, 800, &[(0, 10)], &[], &[5]).unwrap();
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].source, "Title body");
    }
}
