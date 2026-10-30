//! Literal book-scoped speech substitutions. Original EPUB text is never edited.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PronunciationRule {
    pub term: String,
    pub spoken: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PronunciationDictionary {
    pub rules: Vec<PronunciationRule>,
}

impl PronunciationDictionary {
    pub fn validate(&self) -> Result<(), String> {
        if self.rules.len() > 200 {
            return Err("At most 200 pronunciation rules are allowed".into());
        }
        let mut terms = std::collections::BTreeSet::new();
        for rule in &self.rules {
            if rule.term.trim().is_empty()
                || rule.spoken.trim().is_empty()
                || rule.term.chars().count() > 200
                || rule.spoken.chars().count() > 400
                || rule.term.chars().any(char::is_control)
                || rule.spoken.chars().any(char::is_control)
                || !terms.insert(&rule.term)
            {
                return Err(
                    "Pronunciation rules require unique, nonempty bounded literal terms".into(),
                );
            }
        }
        Ok(())
    }

    pub fn identity(&self) -> String {
        let mut rules = self
            .rules
            .iter()
            .map(|rule| (&rule.term, &rule.spoken))
            .collect::<Vec<_>>();
        rules.sort();
        serde_json::to_string(&(1, rules)).expect("literal pronunciation dictionary")
    }

    pub fn apply(&self, source: &str) -> String {
        let mut output = String::new();
        let mut previous = 0;
        for (begin, end, rule) in self.matches(source) {
            output.push_str(&source[previous..begin]);
            output.push_str(&rule.spoken);
            previous = end;
        }
        output.push_str(&source[previous..]);
        output
    }

    pub(crate) fn source_plan(
        &self,
        source: &str,
        initial: usize,
        subsequent: usize,
        paragraph_ends: &[usize],
        heading_ends: &[usize],
    ) -> Result<Vec<crate::tts_session::SourceTextSegment>, crate::tts_session::TtsFailure> {
        let protected = self
            .matches(source)
            .iter()
            .map(|(begin, end, _)| (*begin, *end))
            .collect::<Vec<_>>();
        crate::tts_session::plan_text_with_headings(
            source,
            initial,
            subsequent,
            &protected,
            paragraph_ends,
            heading_ends,
        )
    }

    #[cfg(test)]
    pub(crate) fn source_segments(
        &self,
        source: &str,
        initial: usize,
        subsequent: usize,
    ) -> Vec<String> {
        let ranges = self
            .matches(source)
            .iter()
            .map(|(begin, end, _)| (*begin, *end))
            .collect::<Vec<_>>();
        crate::tts_session::segment_text_protecting(source, initial, subsequent, &ranges)
            .expect("validated speech capacity")
    }

    fn matches<'a>(&'a self, source: &str) -> Vec<(usize, usize, &'a PronunciationRule)> {
        let word = |character: char| character.is_alphanumeric() || character == '_';
        let mut rules = self.rules.iter().collect::<Vec<_>>();
        rules.sort_by_key(|rule| std::cmp::Reverse(rule.term.len()));
        let mut matched_ranges = Vec::new();
        let mut position = 0;
        while position < source.len() {
            let tail = &source[position..];
            let matched = rules.iter().find(|rule| {
                tail.starts_with(&rule.term)
                    && (!rule.term.chars().next().is_some_and(word)
                        || !source[..position].chars().next_back().is_some_and(word))
                    && (!rule.term.chars().next_back().is_some_and(word)
                        || !tail[rule.term.len()..].chars().next().is_some_and(word))
            });
            if let Some(rule) = matched {
                matched_ranges.push((position, position + rule.term.len(), *rule));
                position += rule.term.len();
            } else {
                let character = tail.chars().next().expect("nonempty tail");
                position += character.len_utf8();
            }
        }
        matched_ranges
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn longest_literal_unicode_match_is_not_recursive_and_source_stays_intact() {
        let dictionary = PronunciationDictionary {
            rules: vec![
                PronunciationRule {
                    term: "Dr. Tolkien".into(),
                    spoken: "Professor Tólkien".into(),
                },
                PronunciationRule {
                    term: "Tolkien".into(),
                    spoken: "Tólkien".into(),
                },
                PronunciationRule {
                    term: "Tólkien".into(),
                    spoken: "wrong recursive output".into(),
                },
            ],
        };
        dictionary.validate().unwrap();
        let source = "Dr. Tolkien e Tolkienianos; Tolkien.";
        assert_eq!(
            dictionary.apply(source),
            "Professor Tólkien e Tolkienianos; Tólkien."
        );
        assert_eq!(source, "Dr. Tolkien e Tolkienianos; Tolkien.");
    }
    #[test]
    fn identity_changes_with_effect_and_invalid_terms_are_rejected() {
        let mut first = PronunciationDictionary {
            rules: vec![PronunciationRule {
                term: "Árvore".into(),
                spoken: "árvore".into(),
            }],
        };
        let identity = first.identity();
        first.rules[0].spoken = "ar vore".into();
        assert_ne!(identity, first.identity());
        first.rules.push(first.rules[0].clone());
        assert!(first.validate().is_err());
        assert_eq!(
            PronunciationDictionary::default().apply("untouched"),
            "untouched"
        );
    }

    #[test]
    fn source_segmentation_keeps_a_phrase_crossing_the_initial_boundary_whole() {
        let dictionary = PronunciationDictionary {
            rules: vec![PronunciationRule {
                term: "Dr. Tolkien".into(),
                spoken: "Professor Tólkien".into(),
            }],
        };
        let source = format!("{}Dr. Tolkien continues the story.", "a ".repeat(87));
        let segments = dictionary.source_segments(&source, 180, 800);
        assert!(segments
            .iter()
            .any(|segment| segment.contains("Dr. Tolkien")));
        assert!(segments
            .iter()
            .map(|segment| dictionary.apply(segment))
            .collect::<Vec<_>>()
            .join(" ")
            .contains("Professor Tólkien"));
        assert_eq!(segments.join(" "), source.trim());
        assert_eq!(
            PronunciationDictionary::default().source_segments(&source, 180, 800),
            crate::tts_session::segment_text(&source, 180, 800).unwrap()
        );
    }
}
