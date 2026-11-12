//! Content-validated book language evidence and source-preserving passage routing.
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;

const SAMPLE_CHARS: usize = 1200;
const MAX_SAMPLES: usize = 32;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct BookLanguageAnalysis {
    pub declared: Option<String>,
    pub confirmed: Option<String>,
    pub languages: Vec<String>,
    pub samples_examined: usize,
    pub inconclusive_samples: usize,
    pub detector: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LanguageOverride {
    pub chapter_index: usize,
    pub start: usize,
    pub end: usize,
    pub language: String,
}

impl LanguageOverride {
    pub fn validate(&self) -> Result<(), String> {
        if self.start >= self.end || !valid_tag(&self.language) {
            return Err("Invalid passage language correction".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LanguagePassage {
    pub bytes: Range<usize>,
    pub scalars: Range<usize>,
    pub language: Option<String>,
}

pub fn valid_tag(tag: &str) -> bool {
    let parts = tag.split(['-', '_']).collect::<Vec<_>>();
    (2..=3).contains(&parts[0].len())
        && parts[0].bytes().all(|b| b.is_ascii_alphabetic())
        && parts.iter().skip(1).all(|part| {
            !part.is_empty() && part.len() <= 8 && part.bytes().all(|b| b.is_ascii_alphanumeric())
        })
}

fn base(tag: &str) -> &str {
    tag.split(['-', '_']).next().unwrap_or(tag)
}

fn tag(language: whatlang::Lang, declared: Option<&str>) -> String {
    let detected = match language.code() {
        "por" => "pt-BR",
        "eng" => "en-US",
        "spa" => "es-ES",
        "ita" => "it-IT",
        "fra" => "fr-FR",
        "deu" => "de-DE",
        "rus" => "ru",
        "cmn" => "zh",
        "jpn" => "ja",
        "kor" => "ko",
        "ara" => "ar",
        "hin" => "hi",
        "ben" => "bn",
        "ukr" => "uk",
        "kat" => "ka",
        "heb" => "he",
        "yid" => "yi",
        "pol" => "pl",
        "amh" => "am",
        "jav" => "jv",
        "nob" => "nb",
        "dan" => "da",
        "swe" => "sv",
        "fin" => "fi",
        "tur" => "tr",
        "nld" => "nl",
        "hun" => "hu",
        "ces" => "cs",
        "ell" => "el",
        "bul" => "bg",
        "bel" => "be",
        "mar" => "mr",
        "kan" => "kn",
        "ron" => "ro",
        "slv" => "sl",
        "hrv" => "hr",
        "srp" => "sr",
        "mkd" => "mk",
        "lit" => "lt",
        "lav" => "lv",
        "est" => "et",
        "tam" => "ta",
        "vie" => "vi",
        "urd" => "ur",
        "tha" => "th",
        "guj" => "gu",
        "uzb" => "uz",
        "pan" => "pa",
        "aze" => "az",
        "ind" => "id",
        "tel" => "te",
        "pes" => "fa",
        "mal" => "ml",
        "ori" => "or",
        "mya" => "my",
        "nep" => "ne",
        "sin" => "si",
        "khm" => "km",
        "tuk" => "tk",
        "aka" => "ak",
        "zul" => "zu",
        "sna" => "sn",
        "afr" => "af",
        "lat" => "la",
        "slk" => "sk",
        "cat" => "ca",
        "tgl" => "tl",
        "hye" => "hy",
        "cym" => "cy",
        "epo" => "eo",
        other => other,
    };
    declared
        .filter(|value| valid_tag(value) && base(value).eq_ignore_ascii_case(base(detected)))
        .unwrap_or(detected)
        .replace('_', "-")
}

fn informative(text: &str) -> bool {
    let minimum = match whatlang::detect_script(text) {
        Some(whatlang::Script::Latin) | None => 24,
        _ => 4,
    };
    text.chars()
        .filter(|value| value.is_alphabetic())
        .take(minimum)
        .count()
        >= minimum
}

pub fn detect(text: &str, declared: Option<&str>) -> Option<String> {
    // Distinct scripts carry useful evidence in shorter passages than Latin names.
    if !informative(text) {
        return None;
    }
    let info = whatlang::detect(text)?;
    info.is_reliable().then(|| tag(info.lang(), declared))
}

pub fn markup_language(html: &str) -> Option<String> {
    let mut reader = quick_xml::Reader::from_str(html);
    for _ in 0..128 {
        match reader.read_event() {
            Ok(
                quick_xml::events::Event::Start(element) | quick_xml::events::Event::Empty(element),
            ) => {
                if matches!(element.local_name().as_ref(), b"html" | b"body") {
                    for attribute in element.attributes().flatten() {
                        if matches!(attribute.key.as_ref(), b"lang" | b"xml:lang") {
                            if let Ok(value) = attribute.decoded_and_normalized_value(
                                quick_xml::XmlVersion::Implicit1_0,
                                reader.decoder(),
                            ) {
                                if valid_tag(&value) {
                                    return Some(value.replace('_', "-"));
                                }
                            }
                        }
                    }
                    if element.local_name().as_ref() == b"body" {
                        return None;
                    }
                }
            }
            Err(_) | Ok(quick_xml::events::Event::Eof) => return None,
            _ => {}
        }
    }
    None
}

/// Expand evenly distributed samples instead of repeatedly testing the opening.
/// Unknown content is never turned into a definite language by its metadata alone.
pub fn analyze_book<'a>(
    texts: impl IntoIterator<Item = &'a str>,
    declared: Option<&str>,
    cancelled: &dyn Fn() -> bool,
) -> Result<BookLanguageAnalysis, ()> {
    let mut candidates = Vec::new();
    for text in texts {
        if cancelled() {
            return Err(());
        }
        // Short bilingual chapters need independent evidence too. A single
        // majority prediction over both languages cannot establish consensus.
        for (sentence_start, sentence) in text.split_sentence_bound_indices() {
            if cancelled() {
                return Err(());
            }
            let mut boundaries = Vec::new();
            for (byte, _) in sentence.char_indices().step_by(SAMPLE_CHARS) {
                if cancelled() {
                    return Err(());
                }
                boundaries.push(byte);
            }
            boundaries.push(sentence.len());
            for pair in boundaries.windows(2) {
                let sample = &sentence[pair[0]..pair[1]];
                if informative(sample) {
                    let mut begin = (sentence_start + pair[0]).saturating_sub(400);
                    let mut end = (sentence_start + pair[1] + 400).min(text.len());
                    while !text.is_char_boundary(begin) {
                        begin += 1;
                    }
                    while !text.is_char_boundary(end) {
                        end -= 1;
                    }
                    candidates.push((sample, &text[begin..end]));
                }
            }
        }
    }
    let mut result = BookLanguageAnalysis {
        declared: declared.map(str::to_owned),
        detector: "whatlang-0.18/book-consensus-v1".into(),
        ..Default::default()
    };
    let mut examined = BTreeSet::new();
    let mut languages = BTreeSet::new();
    for requested in [5, 12, MAX_SAMPLES] {
        let count = requested.min(candidates.len());
        for position in 0..count {
            if cancelled() {
                return Err(());
            }
            if result.samples_examined >= MAX_SAMPLES {
                break;
            }
            let index = if count <= 1 {
                0
            } else {
                position * (candidates.len() - 1) / (count - 1)
            };
            if !examined.insert(index) {
                continue;
            }
            result.samples_examined += 1;
            let mut language = detect(candidates[index].0, declared);
            if language.is_none() && result.samples_examined < MAX_SAMPLES {
                if cancelled() {
                    return Err(());
                }
                // An uncertain short sample gets additional source context,
                // never a metadata-only assignment or a discarded contradiction.
                result.samples_examined += 1;
                language = detect(candidates[index].1, declared);
            }
            if let Some(language) = language {
                languages.insert(language);
            } else {
                result.inconclusive_samples += 1;
            }
        }
        if result.inconclusive_samples == 0 && languages.len() == 1 {
            break;
        }
        if examined.len() == candidates.len() {
            break;
        }
    }
    result.languages = languages.into_iter().collect();
    if result.languages.len() == 1 && result.inconclusive_samples == 0 {
        result.confirmed = result.languages.first().cloned();
    }
    Ok(result)
}

/// Retains source order and coordinates; it never interleaves parallel translations.
pub fn passages(
    text: &str,
    paragraph_ends: &[usize],
    fallback: Option<&str>,
    overrides: &[LanguageOverride],
    chapter: usize,
    source_offset: usize,
    manual_language: Option<&str>,
) -> Vec<LanguagePassage> {
    let total = text.chars().count();
    let mut ends = paragraph_ends
        .iter()
        .copied()
        .filter(|end| *end > 0 && *end < total)
        .collect::<BTreeSet<_>>();
    let mut sentence_end = 0;
    for (_, sentence) in text.split_sentence_bound_indices() {
        sentence_end += sentence.chars().count();
        ends.insert(sentence_end);
    }
    ends.insert(total);
    for correction in overrides
        .iter()
        .filter(|value| value.chapter_index == chapter)
    {
        for absolute in [correction.start, correction.end] {
            if let Some(relative) = absolute
                .checked_sub(source_offset)
                .filter(|offset| *offset > 0 && *offset < total)
            {
                ends.insert(relative);
            }
        }
    }
    let boundaries = text
        .char_indices()
        .map(|(byte, _)| byte)
        .chain(std::iter::once(text.len()))
        .enumerate()
        .filter(|(scalar, _)| *scalar == 0 || ends.contains(scalar))
        .collect::<std::collections::BTreeMap<_, _>>();
    let mut result: Vec<LanguagePassage> = Vec::new();
    let mut start = 0;
    for end in ends {
        if end <= start {
            continue;
        }
        let bytes = boundaries[&start]..boundaries[&end];
        let language = overrides
            .iter()
            .rev()
            .find(|value| {
                value.chapter_index == chapter
                    && value.start <= start + source_offset
                    && value.end >= end + source_offset
            })
            .map(|value| value.language.clone())
            .or_else(|| manual_language.map(str::to_owned))
            .or_else(|| detect(&text[bytes.clone()], fallback))
            .or_else(|| {
                let paragraph_start = paragraph_ends
                    .iter()
                    .copied()
                    .filter(|value| *value <= start)
                    .max()
                    .unwrap_or(0);
                let paragraph_end = paragraph_ends
                    .iter()
                    .copied()
                    .filter(|value| *value >= end)
                    .min()
                    .unwrap_or(total);
                detect(
                    &text[boundaries[&paragraph_start]..boundaries[&paragraph_end]],
                    fallback,
                )
            })
            .or_else(|| fallback.map(str::to_owned));
        if let Some(previous) = result.last_mut().filter(|value| value.language == language) {
            previous.bytes.end = bytes.end;
            previous.scalars.end = end;
        } else {
            result.push(LanguagePassage {
                bytes,
                scalars: start..end,
                language,
            });
        }
        start = end;
    }
    for index in 0..result.len() {
        if result[index].language.is_none() && !informative(&text[result[index].bytes.clone()]) {
            // A short heading belongs to the following informative passage;
            // trailing punctuation belongs to the preceding passage.
            result[index].language = result[index + 1..]
                .iter()
                .find_map(|value| value.language.clone())
                .or_else(|| {
                    result[..index]
                        .iter()
                        .rev()
                        .find_map(|value| value.language.clone())
                });
        }
    }
    result
}

/// Legacy and versioned selections expose the same localized recovery contract.
pub fn mismatch_message(language: &str, model: &str, message: &str) -> String {
    let context = serde_json::json!({"language": language, "model_id": model});
    format!("{message} [[tts_language_mismatch_v1]]{context}[[/tts_language_mismatch_v1]]")
}

/// Use a configured language-compatible secondary directly, without recording a failure.
pub fn preferences_for_language(
    preferences: &crate::tts_preferences::TtsPreferences,
    language: Option<&str>,
) -> crate::tts_preferences::TtsPreferences {
    let Some(language) = language else {
        return preferences.clone();
    };
    let supports = |selection: &crate::tts_preferences::TtsSelection| {
        selection
            .model_id
            .as_deref()
            .and_then(|id| {
                crate::model_catalog::MODELS
                    .iter()
                    .find(|model| model.id == id)
            })
            .map(|model| {
                model
                    .languages
                    .iter()
                    .any(|value| value.eq_ignore_ascii_case(base(language)))
            })
            .unwrap_or(true)
    };
    if supports(&preferences.primary) {
        return preferences.clone();
    }
    if let Some(secondary) = preferences
        .secondary
        .as_ref()
        .filter(|selection| supports(selection))
    {
        return crate::tts_preferences::TtsPreferences {
            primary: secondary.clone(),
            secondary: None,
            policy_version: preferences.policy_version,
            allow_online_fallback: preferences.allow_online_fallback,
        };
    }
    preferences.clone()
}

#[cfg(test)]
#[path = "language_tests.rs"]
mod tests;
