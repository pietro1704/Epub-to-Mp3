//! Inclusive "from chapter A to chapter B" resolution shared by embedding clients.
//!
//! Selectors follow `ConversionRequest::chapter_indices`: a chapter's own index
//! (`3`, `1.2`) or a zero-based source position (`position:4`, or a bare number).
//! Resolution never touches jobs, caches or output, so a client can reject an
//! unresolvable range before any conversion side effect.
use super::conversion_input_policy::chapter_selection_matches;
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

/// A range bound that names no chapter of the parsed source.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ChapterRangeError {
    #[error("chapter selector '{selector}' matches no chapter")]
    StartNotFound { selector: String },
    #[error("chapter selector '{selector}' matches no chapter at or after '{start}'")]
    EndNotFound { selector: String, start: String },
}

/// Resolve a range to source positions. The start is the first chapter named by
/// `start`; the end is the first chapter at or after it named by `end`, or the
/// last chapter when `end` is absent. An end that only exists before the start
/// is therefore an error rather than an empty or reversed selection.
///
/// A bound must name exactly one chapter, so a chapter's own index wins over the
/// positional reading of a bare number: with indices `1, 2, 2.1, 2.2, 3`, the
/// bound `3` is the chapter indexed `3`, not zero-based position 3 (`2.2`).
pub fn chapter_range_positions<'a>(
    chapters: impl IntoIterator<Item = (&'a str, &'a str)>,
    start: &str,
    end: Option<&str>,
) -> Result<std::ops::RangeInclusive<usize>, ChapterRangeError> {
    let indices: Vec<(&str, &str)> = chapters.into_iter().collect();
    let first =
        bound_position(&indices, start, 0).ok_or_else(|| ChapterRangeError::StartNotFound {
            selector: start.to_owned(),
        })?;
    let last = match end {
        None => indices.len() - 1,
        Some(end) => {
            bound_position(&indices, end, first).ok_or_else(|| ChapterRangeError::EndNotFound {
                selector: end.to_owned(),
                start: start.to_owned(),
            })?
        }
    };
    Ok(first..=last)
}

fn bound_position(indices: &[(&str, &str)], selector: &str, from: usize) -> Option<usize> {
    // Resolve identity before checking ordering. A literal index before `from`
    // must not be reinterpreted as a positional selector after `from`.
    if let Some(position) = indices.iter().position(|(index, _)| *index == selector) {
        return (position >= from).then_some(position);
    }
    // Parent indices and title snippets retain the legacy range selectors.
    let prefix = format!("{selector}.");
    if let Some(position) = indices
        .iter()
        .position(|(index, _)| index.starts_with(&prefix))
    {
        return (position >= from).then_some(position);
    }
    let normalized = normalize_selector(selector);
    if !selector.starts_with("position:") && normalized.chars().any(char::is_alphabetic) {
        return indices
            .iter()
            .enumerate()
            .skip(from)
            .find(|(_, (_, title))| normalize_selector(title).contains(&normalized))
            .map(|(position, _)| position);
    }
    indices
        .iter()
        .enumerate()
        .skip(from)
        .find(|(position, (index, _))| chapter_selection_matches(selector, index, *position))
        .map(|(position, _)| position)
}

fn normalize_selector(value: &str) -> String {
    value
        .nfkd()
        .filter(|ch| !is_combining_mark(*ch))
        .flat_map(char::to_lowercase)
        .collect::<String>()
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    const INDICES: [(&str, &str); 6] = [
        ("1", "Introdução"),
        ("2", "Mercado"),
        ("2.1", "Frutas"),
        ("2.2", "Pães"),
        ("3", "Biblioteca"),
        ("4", "Conclusão"),
    ];

    #[test]
    fn open_and_closed_ranges_are_inclusive_and_follow_source_order() {
        assert_eq!(chapter_range_positions(INDICES, "2.1", None), Ok(2..=5));
        assert_eq!(
            chapter_range_positions(INDICES, "2", Some("2.2")),
            Ok(1..=3)
        );
        assert_eq!(chapter_range_positions(INDICES, "3", Some("3")), Ok(4..=4));
        assert_eq!(
            chapter_range_positions(INDICES, "position:0", Some("position:1")),
            Ok(0..=1)
        );
    }

    #[test]
    fn a_chapter_index_wins_over_the_positional_reading_of_a_bare_number() {
        // Position 3 is chapter 2.2; the bound "3" still names chapter 3.
        assert_eq!(chapter_range_positions(INDICES, "3", None), Ok(4..=5));
        assert_eq!(chapter_range_positions(INDICES, "1", Some("3")), Ok(0..=4));
        // Without such an index, a bare number is a zero-based position.
        let unnumbered = [
            ("cover", "Cover"),
            ("preface", "Preface"),
            ("story", "Story"),
        ];
        assert_eq!(chapter_range_positions(unnumbered, "1", None), Ok(1..=2));
        assert_eq!(
            chapter_range_positions(unnumbered, "preface", Some("2")),
            Ok(1..=2)
        );
    }

    #[test]
    fn title_snippets_ignore_case_and_accents_and_parent_indices_select_subsections() {
        assert_eq!(
            chapter_range_positions(INDICES, "INTRODUCAO", Some("paes")),
            Ok(0..=3)
        );
        assert_eq!(
            chapter_range_positions(INDICES, "biblio", Some("conclusao")),
            Ok(4..=5)
        );
        assert_eq!(
            chapter_range_positions([("2.1", "One"), ("2.2", "Two"), ("3", "Three")], "2", None),
            Ok(0..=2)
        );
    }

    #[test]
    fn unknown_or_reversed_bounds_are_rejected_instead_of_selecting_nothing() {
        assert!(chapter_range_positions(INDICES, "2", Some("1")).is_err());
        assert_eq!(
            chapter_range_positions(INDICES, "9.9", None),
            Err(ChapterRangeError::StartNotFound {
                selector: "9.9".into()
            })
        );
        let reversed = ChapterRangeError::EndNotFound {
            selector: "1".into(),
            start: "3".into(),
        };
        assert_eq!(
            chapter_range_positions(INDICES, "3", Some("1")),
            Err(reversed.clone())
        );
        assert!(reversed.to_string().contains("at or after '3'"));
        assert!(chapter_range_positions(std::iter::empty(), "1", None).is_err());
        assert!(chapter_range_positions(INDICES, "2", Some("chapter-nine")).is_err());
    }
}
