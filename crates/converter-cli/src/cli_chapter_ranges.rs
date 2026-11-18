//! Chapter-range flags: literal syntax and resolution against the parsed book.
//!
//! Resolution only reads book metadata, so an unknown or reversed range is
//! rejected before any job, cache or output exists for the invocation.
use converter_core::embedded::EmbeddedBookMetadata;

pub(super) const TO_END: &str = "--from-chapter-to-end";
pub(super) const TO_CHAPTER: &str = "--from-chapter-to-chapter";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ChapterRange {
    /// The flag that supplied the range, for error messages.
    pub(super) flag: &'static str,
    pub(super) start: String,
    /// Inclusive end selector; absent means the last chapter of the book.
    pub(super) end: Option<String>,
}

impl ChapterRange {
    pub(super) fn parse(flag: &'static str, value: &str) -> Result<Self, String> {
        if flag == TO_END {
            let start = value.trim();
            if start.is_empty() {
                return Err(format!("{TO_END} requires a chapter selector"));
            }
            return Ok(Self {
                flag,
                start: start.to_owned(),
                end: None,
            });
        }
        // Keep the legacy separators while reserving position:N's colon.
        let (start, end) = value
            .split_once("..")
            .or_else(|| value.split_once(','))
            .or_else(|| (!value.contains("position:")).then(|| value.split_once(':')).flatten())
            .map(|(start, end)| (start.trim(), end.trim()))
            .filter(|(start, end)| !start.is_empty() && !end.is_empty())
            .ok_or_else(|| {
                format!("{TO_CHAPTER} requires an inclusive range A..B (for example 2..5), got '{value}'")
            })?;
        Ok(Self {
            flag,
            start: start.to_owned(),
            end: Some(end.to_owned()),
        })
    }
}

/// Explicit `position:N` selectors for the chapters of `range`, narrowed to the
/// chapters that also match one of `selectors` when any were given.
pub(super) fn range_selection(
    metadata: &EmbeddedBookMetadata,
    range: &ChapterRange,
    selectors: &[String],
) -> Result<Vec<String>, String> {
    let indices: Vec<&str> = metadata
        .chapters
        .iter()
        .map(|chapter| chapter.index.as_str())
        .collect();
    let positions = converter_core::worker::chapter_range_positions(
        metadata
            .chapters
            .iter()
            .map(|chapter| (chapter.index.as_str(), chapter.name.as_str())),
        &range.start,
        range.end.as_deref(),
    )
    .map_err(|error| format!("{}: {error}", range.flag))?;
    let selected: Vec<usize> = positions
        .filter(|&position| {
            selectors.is_empty()
                || selectors.iter().any(|selector| {
                    narrowed_selector_position(&indices, selector) == Some(position)
                })
        })
        .collect();
    if selected.is_empty() {
        return Err(format!(
            "{}: no --chapter or --section selector matches a chapter inside the range",
            range.flag
        ));
    }
    if selected
        .iter()
        .all(|&position| metadata.chapters[position].text.trim().is_empty())
    {
        return Err(format!(
            "{}: the selected chapters have no readable text",
            range.flag
        ));
    }
    Ok(selected
        .into_iter()
        .map(|position| format!("position:{position}"))
        .collect())
}

/// Narrowing a range uses one chapter identity, like its bounds. A literal
/// index wins over the positional reading of a bare number, including when
/// that chapter lies outside the range; it must not select a second chapter.
fn narrowed_selector_position(indices: &[&str], selector: &str) -> Option<usize> {
    if let Some(position) = selector.strip_prefix("position:") {
        return position
            .parse::<usize>()
            .ok()
            .filter(|position| *position < indices.len());
    }
    indices
        .iter()
        .position(|index| *index == selector)
        .or_else(|| {
            selector
                .parse::<usize>()
                .ok()
                .filter(|position| *position < indices.len())
        })
}
