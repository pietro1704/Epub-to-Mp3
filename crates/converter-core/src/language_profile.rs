//! Whole-book language profile (card BOOK-LANGUAGE-PROFILE).
//!
//! The detector reads the entire text of the book once and classifies it: a monolingual book
//! (quotations in other languages do not count), a bilingual / parallel-text book, or a book
//! that is multilingual by section, with the share of each language. The profile is cached by
//! the book identity, so playback never pays for it twice and never waits on a detector in its
//! hot path. A monolingual book is narrated entirely with the voice of its main language.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

pub const PROFILE_VERSION: u32 = 2;
/// Part of the cache identity of both the profile and the narration it routes.
pub const DETECTOR: &str = "whatlang-0.18/book-profile-v1";
/// A language is part of the book when it is at least this share of the detected text...
const MIN_LANGUAGE_FRACTION: f64 = 0.10;
/// ...or when it fills one uninterrupted section of at least this many characters
/// (about a page). Anything shorter is a quotation, whatever the number of quotations.
const MIN_SECTION_CHARS: usize = 1_500;
/// Sentences are grouped into windows of about this many letters before they are classified:
/// a single short sentence is not reliable evidence of a language.
const WINDOW_LETTERS: usize = 160;
/// The declared language breaks a tie only when the two largest languages are this close (share of the text).
const TIE_POINTS: f64 = 0.05;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BookLanguageClass {
    Monolingual,
    /// Two languages, as parallel text or in alternating sections.
    Bilingual,
    /// Three or more languages, by section.
    Multilingual,
}

/// What a language is to the book (design 2026-11-24): the voice that reads everything without its own
/// (`Main`), a language that is 10% or more of the text (`Significant`), or one that only fills sections of
/// 1,500 characters or more (`Section`). Languages found only in quotations are listed as `incidental`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum LanguageRole {
    #[default]
    Main,
    Significant,
    Section,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LanguageShare {
    /// BCP 47 tag (the declared region is kept when the base language matches).
    pub language: String,
    pub chars: usize,
    /// Share of the characters whose language could be determined, 0.0..=1.0.
    pub fraction: f64,
    /// The longest uninterrupted section in this language, in characters.
    pub longest_section_chars: usize,
    /// Additive: absent from a profile written before roles existed (read as `Main`).
    #[serde(default)]
    pub role: LanguageRole,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BookLanguageProfile {
    pub version: u32,
    pub detector: String,
    pub class: BookLanguageClass,
    /// The language with the most text; the voice that reads anything without its own voice.
    pub primary: Option<String>,
    /// The languages the book is written in (the primary first), by decreasing share.
    pub languages: Vec<LanguageShare>,
    /// Languages found only in short quotations: they never route a passage.
    pub incidental: Vec<String>,
    pub total_chars: usize,
    pub undetermined_chars: usize,
}

impl BookLanguageProfile {
    /// The language to read the whole book in when it is monolingual.
    pub fn monolingual_language(&self) -> Option<&str> {
        (self.class == BookLanguageClass::Monolingual)
            .then_some(self.primary.as_deref())
            .flatten()
    }

    /// Whether `language` (any tag) is one the book is written in.
    pub fn includes(&self, language: &str) -> bool {
        let wanted = super::base(language);
        self.languages
            .iter()
            .any(|share| super::base(&share.language).eq_ignore_ascii_case(wanted))
    }
}

/// Classify the whole book. `texts` are the chapter texts in reading order.
pub fn profile<'a>(
    texts: impl IntoIterator<Item = &'a str>,
    declared: Option<&str>,
    cancelled: &dyn Fn() -> bool,
) -> Result<BookLanguageProfile, ()> {
    // (base language, tag, characters) of each classified window, in reading order.
    let mut windows: Vec<(String, String, usize)> = Vec::new();
    let mut undetermined = 0usize;
    let mut total = 0usize;
    for text in texts {
        let mut window = String::new();
        let mut letters = 0usize;
        let flush = |window: &mut String,
                     letters: &mut usize,
                     windows: &mut Vec<_>,
                     undetermined: &mut usize| {
            if window.is_empty() {
                return;
            }
            let chars = window.chars().count();
            match super::detect(window, declared) {
                Some(tag) => windows.push((super::base(&tag).to_ascii_lowercase(), tag, chars)),
                None => *undetermined += chars,
            }
            window.clear();
            *letters = 0;
        };
        for sentence in text.split_sentence_bounds() {
            if cancelled() {
                return Err(());
            }
            total += sentence.chars().count();
            window.push_str(sentence);
            letters += sentence
                .chars()
                .filter(|value| value.is_alphabetic())
                .count();
            if letters >= WINDOW_LETTERS {
                flush(&mut window, &mut letters, &mut windows, &mut undetermined);
            }
        }
        flush(&mut window, &mut letters, &mut windows, &mut undetermined);
    }

    let mut chars: BTreeMap<String, usize> = BTreeMap::new();
    let mut tags: BTreeMap<String, String> = BTreeMap::new();
    let mut longest: BTreeMap<String, usize> = BTreeMap::new();
    let mut run: Option<(String, usize)> = None;
    for (base, tag, count) in &windows {
        *chars.entry(base.clone()).or_default() += count;
        // Prefer the tag that carries the declared region.
        let entry = tags.entry(base.clone()).or_insert_with(|| tag.clone());
        if declared
            .is_some_and(|declared| entry.as_str() != tag && tag.eq_ignore_ascii_case(declared))
        {
            *entry = tag.clone();
        }
        match &mut run {
            Some((current, length)) if current == base => *length += count,
            _ => {
                if let Some((previous, length)) = run.take() {
                    let best = longest.entry(previous).or_default();
                    *best = (*best).max(length);
                }
                run = Some((base.clone(), *count));
            }
        }
    }
    if let Some((previous, length)) = run {
        let best = longest.entry(previous).or_default();
        *best = (*best).max(length);
    }

    let detected: usize = chars.values().sum();
    let mut shares: Vec<LanguageShare> = chars
        .iter()
        .map(|(base, count)| LanguageShare {
            language: tags[base].clone(),
            chars: *count,
            fraction: if detected == 0 {
                0.0
            } else {
                *count as f64 / detected as f64
            },
            longest_section_chars: longest.get(base).copied().unwrap_or(0),
            role: LanguageRole::Main,
        })
        .collect();
    shares.sort_by(|a, b| {
        b.chars
            .cmp(&a.chars)
            .then_with(|| a.language.cmp(&b.language))
    });
    // The file's declared language never outweighs the text; it only breaks a near tie between the two largest.
    if let (Some(declared), true) = (declared, shares.len() >= 2) {
        let wanted = super::base(declared);
        if !super::base(&shares[0].language).eq_ignore_ascii_case(wanted)
            && super::base(&shares[1].language).eq_ignore_ascii_case(wanted)
            && shares[0].fraction - shares[1].fraction <= TIE_POINTS
        {
            shares.swap(0, 1);
        }
    }
    let primary = shares.first().map(|share| share.language.clone());
    let (languages, incidental): (Vec<_>, Vec<_>) =
        shares.into_iter().enumerate().partition(|(index, share)| {
            *index == 0
                || share.fraction >= MIN_LANGUAGE_FRACTION
                || share.longest_section_chars >= MIN_SECTION_CHARS
        });
    let languages: Vec<LanguageShare> = languages
        .into_iter()
        .map(|(index, mut share)| {
            share.role = if index == 0 {
                LanguageRole::Main
            } else if share.fraction >= MIN_LANGUAGE_FRACTION {
                LanguageRole::Significant
            } else {
                LanguageRole::Section
            };
            share
        })
        .collect();
    let class = match languages.len() {
        0 | 1 => BookLanguageClass::Monolingual,
        2 => BookLanguageClass::Bilingual,
        _ => BookLanguageClass::Multilingual,
    };
    Ok(BookLanguageProfile {
        version: PROFILE_VERSION,
        detector: DETECTOR.into(),
        class,
        primary,
        languages,
        incidental: incidental
            .into_iter()
            .map(|(_, share)| share.language)
            .collect(),
        total_chars: total,
        undetermined_chars: undetermined,
    })
}

/// The cached profile of a book, or a fresh one stored for next time. `identity` names the book
/// (its source identity); a profile made by another detector or version is recomputed. Native
/// builds only: the browser build has no cache directory.
#[cfg(not(target_arch = "wasm32"))]
pub fn load_or_compute<'a>(
    path: &std::path::Path,
    identity: &str,
    texts: impl IntoIterator<Item = &'a str>,
    declared: Option<&str>,
    cancelled: &dyn Fn() -> bool,
) -> Result<BookLanguageProfile, ()> {
    #[derive(Serialize, Deserialize)]
    struct Stored {
        identity: String,
        declared: Option<String>,
        profile: BookLanguageProfile,
    }
    if let Some(stored) = std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Stored>(&bytes).ok())
        .filter(|stored| {
            stored.identity == identity
                && stored.declared.as_deref() == declared
                && stored.profile.version == PROFILE_VERSION
                && stored.profile.detector == DETECTOR
        })
    {
        return Ok(stored.profile);
    }
    let computed = profile(texts, declared, cancelled)?;
    // The cache is an optimization: a failed write never fails the book.
    let _ = crate::cache::atomic_write_json(
        path,
        &Stored {
            identity: identity.to_owned(),
            declared: declared.map(str::to_owned),
            profile: computed.clone(),
        },
    );
    Ok(computed)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PT: &str = "A tarde caiu devagar sobre a casa do jardim e ninguém ousou romper o silêncio que se instalara entre as velhas paredes. ";
    const EN: &str = "The afternoon fell slowly over the house in the garden and nobody dared to break the silence that had settled between the old walls. ";
    const FR: &str = "Il faut cultiver notre jardin, disait le vieux philosophe, car le monde est trop vaste pour que nous puissions le changer tout entier. ";

    fn repeat(text: &str, times: usize) -> String {
        text.repeat(times)
    }

    fn classify(texts: &[String]) -> BookLanguageProfile {
        profile(texts.iter().map(String::as_str), Some("pt-BR"), &|| false).unwrap()
    }

    #[test]
    fn quotations_in_other_languages_do_not_make_a_book_multilingual() {
        // 60 Portuguese paragraphs, 5 short French quotations scattered through them.
        let mut chapter = String::new();
        for index in 0..60 {
            chapter.push_str(&repeat(PT, 3));
            if index % 12 == 6 {
                chapter.push_str(FR);
            }
        }
        let profile = classify(&[chapter]);
        assert_eq!(profile.class, BookLanguageClass::Monolingual, "{profile:?}");
        assert_eq!(profile.monolingual_language(), Some("pt-BR"));
        assert_eq!(profile.languages.len(), 1);
        assert!(
            profile
                .incidental
                .iter()
                .any(|language| language.starts_with("fr")),
            "{profile:?}"
        );
        assert!(profile.languages[0].fraction > 0.9);
    }

    #[test]
    fn parallel_text_is_bilingual_with_each_languages_share() {
        let mut chapter = String::new();
        for _ in 0..30 {
            chapter.push_str(&repeat(PT, 2));
            chapter.push_str(&repeat(EN, 2));
        }
        let profile = classify(&[chapter]);
        assert_eq!(profile.class, BookLanguageClass::Bilingual, "{profile:?}");
        assert_eq!(profile.languages.len(), 2);
        assert!(
            profile.languages.iter().all(|share| share.fraction > 0.3),
            "{profile:?}"
        );
        assert_eq!(profile.monolingual_language(), None);
        assert!(profile.includes("en-US") && profile.includes("pt"));
        assert!(!profile.includes("fr"));
    }

    #[test]
    fn a_book_with_whole_sections_in_three_languages_is_multilingual() {
        let chapters = [repeat(PT, 40), repeat(EN, 40), repeat(FR, 40)];
        let profile = classify(&chapters);
        assert_eq!(
            profile.class,
            BookLanguageClass::Multilingual,
            "{profile:?}"
        );
        assert_eq!(profile.languages.len(), 3);
        assert!(profile
            .languages
            .iter()
            .all(|share| share.longest_section_chars >= MIN_SECTION_CHARS));
    }

    #[test]
    fn the_profile_is_cached_by_book_identity_and_detector() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("language-profile-v1.json");
        let first = load_or_compute(
            &path,
            "book-a",
            [repeat(PT, 30).as_str()],
            Some("pt-BR"),
            &|| false,
        )
        .unwrap();
        // The same book never reads its text again: an empty text returns the stored profile.
        let again = load_or_compute(&path, "book-a", [""], Some("pt-BR"), &|| false).unwrap();
        assert_eq!(first, again);
        // Another book (or another declared language) is recomputed.
        let other = load_or_compute(
            &path,
            "book-b",
            [repeat(EN, 30).as_str()],
            Some("pt-BR"),
            &|| false,
        )
        .unwrap();
        assert_eq!(other.primary.as_deref().map(|tag| &tag[..2]), Some("en"));
    }

    #[test]
    fn cancellation_stops_the_scan_and_an_empty_book_has_no_primary() {
        assert!(profile([repeat(PT, 5).as_str()], None, &|| true).is_err());
        let empty = profile([""], None, &|| false).unwrap();
        assert_eq!(empty.primary, None);
        assert_eq!(empty.class, BookLanguageClass::Monolingual);
    }
}
