//! Matching uses one canonical text axis and never slices within a surrogate.
use super::{bounded, Result, MAX_MATCHES};

#[derive(Debug, Clone)]
pub(super) struct TextRange {
    pub start: usize,
    pub end: usize,
}

pub(super) fn search(text: &str, query: &str) -> Result<Vec<TextRange>> {
    let query: String = query.trim().chars().flat_map(char::to_lowercase).collect();
    if query.is_empty() {
        return Ok(Vec::new());
    }
    let mut folded = String::new();
    let mut boundaries = Vec::new();
    let mut offset = 0;
    for character in text.chars() {
        boundaries.push((folded.len(), offset));
        folded.extend(character.to_lowercase());
        offset += character.len_utf16();
    }
    boundaries.push((folded.len(), offset));
    let boundary = |byte| {
        boundaries
            .binary_search_by_key(&byte, |(position, _)| *position)
            .ok()
            .map(|index| boundaries[index].1)
    };
    let mut ranges = Vec::new();
    for (byte, matched) in folded.match_indices(&query) {
        // A partial case-fold expansion is not a complete source character.
        if let (Some(start), Some(end)) = (boundary(byte), boundary(byte + matched.len())) {
            ranges.push(TextRange { start, end });
            bounded(ranges.len(), MAX_MATCHES, "search matches")?;
        }
    }
    Ok(ranges)
}

pub(super) fn audio(text: &str, query: &str) -> Option<TextRange> {
    let query = query.trim();
    if query.is_empty() {
        return None;
    }
    let byte = text.find(query)?;
    let start = text[..byte].encode_utf16().count();
    Some(TextRange {
        start,
        end: start + query.encode_utf16().count(),
    })
}
