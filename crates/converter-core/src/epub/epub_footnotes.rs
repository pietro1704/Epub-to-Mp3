//! Footnote bodies for one chapter, mirroring the Apple fallback parser: only
//! explicitly linked notes are read (`<a href="…#id">` whose target looks like
//! a footnote or note), each target document is bounded, and the result is
//! plain text so no clients need to render markup.
use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek};

use scraper::{ElementRef, Html};
use zip::ZipArchive;

use super::epub_resources::{read_entry, EpubReadBudget};

/// One footnote body found for a chapter.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Footnote {
    /// The reference label shown in the chapter text, when there is one.
    pub number: Option<String>,
    pub text: String,
}

/// A target document is never larger than this many bytes.
const MAX_TARGET_BYTES: usize = 2 * 1024 * 1024;
/// Notes per chapter and distinct target documents per book.
const MAX_NOTES_PER_CHAPTER: usize = 512;
const MAX_TARGET_DOCUMENTS: usize = 64;
/// A single note body is cut at this many bytes (on a character boundary).
const MAX_NOTE_BYTES: usize = 8 * 1024;

/// Parsed target documents, shared by every chapter of one book so a notes
/// file is read and parsed once.
#[derive(Default)]
pub(super) struct FootnoteTargets {
    documents: HashMap<String, Option<Html>>,
}

/// Cheap pre-check so chapters without any note-like link are never parsed.
fn may_contain_note_links(html: &str) -> bool {
    let lower = html.to_ascii_lowercase();
    lower.contains("href") && (lower.contains("foot") || lower.contains("note"))
}

/// Footnotes of one chapter. `chapter_path` is the archive path of the chapter
/// document; link targets are resolved relative to it. Unreadable or oversized
/// targets are skipped: notes are optional and must never fail a book.
pub(super) fn chapter_footnotes<R: Read + Seek>(
    html: &str,
    chapter_path: &str,
    archive: &mut ZipArchive<R>,
    budget: &mut EpubReadBudget,
    targets: &mut FootnoteTargets,
) -> Vec<Footnote> {
    if !may_contain_note_links(html) {
        return Vec::new();
    }
    let chapter = Html::parse_document(html);
    let mut notes = Vec::new();
    let mut seen = HashSet::new();
    for anchor in chapter
        .tree
        .root()
        .descendants()
        .filter_map(ElementRef::wrap)
    {
        if notes.len() >= MAX_NOTES_PER_CHAPTER {
            break;
        }
        if anchor.value().name() != "a" {
            continue;
        }
        let Some(href) = anchor.value().attr("href") else {
            continue;
        };
        let Some((target, fragment)) = href.trim().split_once('#') else {
            continue;
        };
        let fragment = percent_decode(fragment);
        if fragment.is_empty() {
            continue;
        }
        let marker = format!("{target}#{fragment}").to_ascii_lowercase();
        if !marker.contains("foot") && !marker.contains("note") {
            continue;
        }
        let Some(path) = target_path(chapter_path, target) else {
            continue;
        };
        let body = if path == chapter_path {
            element_text_by_id(&chapter, &fragment)
        } else {
            let Some(document) = targets.document(&path, archive, budget) else {
                continue;
            };
            element_text_by_id(document, &fragment)
        };
        let Some(text) = body else { continue };
        let number = collapse(anchor.text());
        let number = (!number.is_empty()).then_some(number);
        let key = format!("{}|{text}", number.as_deref().unwrap_or(""));
        if seen.insert(key) {
            notes.push(Footnote { number, text });
        }
    }
    notes
}

impl FootnoteTargets {
    fn document<R: Read + Seek>(
        &mut self,
        path: &str,
        archive: &mut ZipArchive<R>,
        budget: &mut EpubReadBudget,
    ) -> Option<&Html> {
        if !self.documents.contains_key(path) {
            if self.documents.len() >= MAX_TARGET_DOCUMENTS {
                return None;
            }
            let parsed = read_entry(archive, path, budget)
                .ok()
                .filter(|source| source.len() <= MAX_TARGET_BYTES)
                .map(|source| Html::parse_document(&source));
            self.documents.insert(path.to_owned(), parsed);
        }
        self.documents.get(path).and_then(Option::as_ref)
    }
}

fn target_path(chapter_path: &str, target: &str) -> Option<String> {
    let target = percent_decode(target.trim());
    if target.starts_with('/') || target.contains(['\\', ':', '?']) {
        return None;
    }
    if target.is_empty() {
        return Some(chapter_path.to_owned());
    }
    let mut parts: Vec<&str> = chapter_path.split('/').collect();
    parts.pop();
    for part in target.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            other => parts.push(other),
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

fn element_text_by_id(document: &Html, id: &str) -> Option<String> {
    let element = document
        .tree
        .root()
        .descendants()
        .filter_map(ElementRef::wrap)
        .find(|element| {
            element.value().attr("id") == Some(id) || element.value().attr("xml:id") == Some(id)
        })?;
    let text = collapse(element.text());
    if text.is_empty() {
        return None;
    }
    Some(truncate(text, MAX_NOTE_BYTES))
}

fn collapse<'a>(parts: impl Iterator<Item = &'a str>) -> String {
    parts
        .flat_map(str::split_whitespace)
        .collect::<Vec<_>>()
        .join(" ")
}

fn truncate(mut text: String, limit: usize) -> String {
    if text.len() > limit {
        let mut end = limit;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

fn percent_decode(value: &str) -> String {
    percent_encoding::percent_decode_str(value)
        .decode_utf8()
        .map(|decoded| decoded.into_owned())
        .unwrap_or_else(|_| value.to_owned())
}
