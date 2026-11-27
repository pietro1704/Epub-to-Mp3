//! Text-layer PDF ingestion. OCR is a separate, explicit capability.
use super::IngestionError;
use crate::epub::{Book, Chapter};
use pdf_extract::{decode_text_string, Document, Object, PlainTextOutput};
use std::path::Path;

/// A page needs this many non-space characters to count as having a text layer.
const MIN_READABLE_CHARS: usize = 20;
/// Books shorter than this are never judged as scans (a cover plus a few short pages).
const MIN_PAGES_FOR_SCAN_CHECK: usize = 5;

pub(crate) const MAX_SOURCE_BYTES: usize = 256 * 1024 * 1024;

pub struct PdfTextIngestion;
impl PdfTextIngestion {
    pub fn from_bytes(path: &Path, source: &[u8]) -> Result<Book, IngestionError> {
        Self::from_bytes_with_cancel(path, source, &|| false)
    }

    pub fn from_bytes_with_cancel(
        path: &Path,
        source: &[u8],
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Book, IngestionError> {
        // The dependency has fallible-input paths implemented with panics. Do not
        // let malformed content unwind across the embedded C ABI boundary.
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            Self::extract(path, source, cancelled)
        }))
        .map_err(|_| extraction_error("malformed or unsupported PDF content"))?
    }

    fn extract(
        path: &Path,
        source: &[u8],
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Book, IngestionError> {
        if cancelled() {
            return Err(IngestionError::Cancelled);
        }
        if source.len() > MAX_SOURCE_BYTES {
            return Err(invalid("PDF exceeds the 256 MiB input limit"));
        }
        let mut doc = Document::load_mem(source).map_err(extraction_error)?;
        if doc.is_encrypted() {
            doc.decrypt("")
                .map_err(|_| invalid("This PDF requires a password before its text can be read"))?;
        }
        repair_cmap_names(&mut doc);
        let pages = doc.get_pages();
        if pages.is_empty() || pages.len() > 20_000 {
            return Err(invalid(
                "PDF page count is empty or exceeds the 20000-page limit",
            ));
        }
        let labels = super::pdf_page_labels::labels(&doc, pages.len())?;
        let mut text = Vec::new();
        let mut total = 0usize;
        let mut skipped_pages = 0usize;
        let mut drawn_without_text = false;
        let mut readable_pages = 0usize;
        for (number, page_id) in &pages {
            if cancelled() {
                return Err(IngestionError::Cancelled);
            }
            let mut page = String::new();
            // Per-page extraction errors must never truncate a book silently.
            pdf_extract::output_doc_page(&doc, &mut PlainTextOutput::new(&mut page), *number)
                .map_err(extraction_error)?;
            page = normalize_page(page.trim());
            // Covers, figures and blank pages have nothing to narrate: skip and count them.
            if page.trim().is_empty() {
                skipped_pages += 1;
                drawn_without_text |= has_drawn_content(&doc, *page_id)?;
            }
            if page.chars().filter(|c| !c.is_whitespace()).count() >= MIN_READABLE_CHARS {
                readable_pages += 1;
            } else if !page.trim().is_empty() {
                // A stray mark on a scanned page is not a text layer.
                drawn_without_text |= has_drawn_content(&doc, *page_id)?;
            }
            total = total.saturating_add(page.len());
            if total > 32 * 1024 * 1024 {
                return Err(invalid("PDF extracted text exceeds the 32 MiB limit"));
            }
            text.push(page);
        }
        // A scan with an OCR artefact or two per page has pages, but nothing to narrate.
        let nearly_textless = text.len() >= MIN_PAGES_FOR_SCAN_CHECK
            && readable_pages.saturating_mul(20) < text.len();
        if skipped_pages == text.len() || nearly_textless {
            if drawn_without_text {
                return Err(invalid(
                    "No PDF page has selectable text; OCR is required before narration",
                ));
            }
            return Err(IngestionError::NoReadableText);
        }
        if cancelled() {
            return Err(IngestionError::Cancelled);
        }
        strip_running_lines(&mut text);
        let (toc, starts) = super::pdf_outline::structure(&doc, &pages)?;
        let mut chapters = Vec::new();
        let starts = if starts.is_empty() {
            heading_starts(&text)
        } else {
            starts
        };
        let starts = if starts.is_empty() {
            (0..text.len())
                .map(|i| (i, format!("Page {}", labels[i]), 1))
                .collect()
        } else {
            starts
        };
        for (position, (start, title, level)) in starts.iter().enumerate() {
            let end = starts.get(position + 1).map_or(text.len(), |next| next.0);
            let content = text[*start..end].join("\n\n");
            let (content, paragraph_ends) = reflow_paragraphs(&content);
            chapters.push(Chapter {
                index: (position + 1).to_string(),
                name: title.clone(),
                source_path: format!("page-{}", start + 1),
                text: content,
                paragraph_ends,
                heading_ends: Vec::new(),
                level: *level,
                footnotes: Vec::new(),
                note_marks: Vec::new(),
                anchors: Vec::new(),
            });
        }
        Ok(Book {
            title: info(&doc, b"Title")
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| {
                    path.file_stem()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned()
                }),
            author: info(&doc, b"Author").unwrap_or_default(),
            language: doc
                .catalog()
                .ok()
                .and_then(|cat| cat.get(b"Lang").ok())
                .and_then(|o| decode_text_string(o).ok()),
            chapters,
            toc,
            cover: None,
            cover_mime: None,
            skipped_pages,
        })
    }
}
// calibre writes `/CMapName Font-cmap def` without the slash on the value. The CMap lexer
// used by `pdf_extract` silently stops at that hyphen, so every glyph decodes to nothing.
// The name does not take part in decoding: drop the malformed line.
fn repair_cmap_names(doc: &mut Document) {
    // Fonts may be objects of their own or inline in a resource dictionary.
    let mut pending: Vec<&Object> = doc.objects.values().collect();
    let mut maps = Vec::new();
    while let Some(object) = pending.pop() {
        match object {
            Object::Dictionary(dictionary) => {
                if let Ok(id) = dictionary.get(b"ToUnicode").and_then(Object::as_reference) {
                    maps.push(id);
                }
                pending.extend(dictionary.iter().map(|(_, value)| value));
            }
            Object::Array(items) => pending.extend(items),
            _ => {}
        }
    }
    for id in maps {
        let Ok(stream) = doc
            .get_object_mut(id)
            .and_then(|object| object.as_stream_mut())
        else {
            continue;
        };
        let content = stream
            .decompressed_content()
            .unwrap_or_else(|_| stream.content.clone());
        let malformed = |line: &[u8]| {
            line.trim_ascii()
                .strip_prefix(b"/CMapName")
                .is_some_and(|value| !value.trim_ascii_start().starts_with(b"/"))
        };
        let is_break = |byte: &u8| matches!(byte, b'\r' | b'\n');
        if content.split(is_break).any(malformed) {
            let kept: Vec<&[u8]> = content
                .split(is_break)
                .filter(|line| !malformed(line))
                .collect();
            stream.set_plain_content(kept.join(&b'\n'));
        }
    }
}

// Distinguishes a scanned book (OCR would help) from a PDF with only blank pages.
fn has_drawn_content(doc: &Document, page: pdf_extract::ObjectId) -> Result<bool, IngestionError> {
    let bytes = doc.get_page_content(page).map_err(extraction_error)?;
    let content = pdf_extract::content::Content::decode(&bytes).map_err(extraction_error)?;
    Ok(content
        .operations
        .iter()
        .any(|operation| matches!(operation.operator.as_str(), "Do" | "BI")))
}

/// Lines shorter than this share of the typical line width may end a paragraph.
const SHORT_LINE_RATIO: f64 = 0.7;

/// True for a line that is only a chapter marker: "Capítulo 3", "CHAPTER IV", "Parte 2" or a
/// lone uppercase Roman numeral.
fn is_heading_line(line: &str) -> bool {
    let line = line.trim();
    let numeral = |w: &str| {
        !w.is_empty()
            && (w.chars().all(|c| c.is_ascii_digit()) && w.len() <= 4
                || w.len() <= 8 && w.chars().all(|c| "IVXLCDMivxlcdm".contains(c)))
    };
    let mut words = line.split_whitespace();
    match (words.next(), words.next(), words.next()) {
        (Some(w), None, None) => w.len() <= 8 && w.chars().all(|c| "IVXLCDM".contains(c)),
        (Some(w), Some(n), None) => {
            let w = w.to_lowercase();
            matches!(
                w.as_str(),
                "capítulo" | "capitulo" | "chapter" | "parte" | "part" | "capítol" | "chapitre"
            ) && numeral(n)
        }
        _ => false,
    }
}

/// Without an outline, a page whose first line is a chapter marker starts a chapter. Needs at
/// least two such pages, and a page packed with markers (a table of contents) never counts.
/// Falls back to one chapter per page, which stays the navigation anchor.
fn heading_starts(pages: &[String]) -> Vec<(usize, String, u32)> {
    let heading = |page: &String| -> Option<String> {
        let mut lines = page.lines().map(str::trim).filter(|l| !l.is_empty());
        let first = lines.next().filter(|l| is_heading_line(l))?;
        let markers = page.lines().filter(|l| is_heading_line(l)).count();
        (markers < 3).then(|| first.to_string())
    };
    let found: Vec<(usize, String)> = pages
        .iter()
        .enumerate()
        .filter_map(|(i, p)| heading(p).map(|h| (i, h)))
        .collect();
    if found.len() < 2 {
        return Vec::new();
    }
    let mut starts = Vec::new();
    if found[0].0 > 0 {
        starts.push((0, "Front matter".to_string(), 1));
    }
    starts.extend(found.into_iter().map(|(i, h)| (i, h, 1)));
    starts
}

/// Maps typographic ligatures to letters, drops NULs and collapses runs of blanks (newlines stay).
fn normalize_page(page: &str) -> String {
    let mut out = String::with_capacity(page.len());
    let mut blank = false;
    for ch in page.chars() {
        let mapped = match ch {
            '\0' => continue,
            '\u{fb00}' => "ff",
            '\u{fb01}' => "fi",
            '\u{fb02}' => "fl",
            '\u{fb03}' => "ffi",
            '\u{fb04}' => "ffl",
            '\u{fb05}' | '\u{fb06}' => "st",
            ' ' | '\t' | '\u{a0}' => {
                if !blank {
                    out.push(' ');
                }
                blank = true;
                continue;
            }
            other => {
                blank = false;
                out.push(other);
                continue;
            }
        };
        blank = false;
        out.push_str(mapped);
    }
    out
}

/// Running headers, footers and page numbers repeat on many pages. The first and last line of
/// a page are dropped when the same line (digits aside) leads or ends at least three pages.
fn strip_running_lines(pages: &mut [String]) {
    if pages.len() < 3 {
        return;
    }
    let key = |line: &str| -> Option<String> {
        let line = line.trim();
        (!line.is_empty() && line.chars().count() <= 80).then(|| {
            line.chars()
                .map(|c| if c.is_ascii_digit() { '#' } else { c })
                .collect()
        })
    };
    let edges = |page: &str| -> Vec<String> {
        let lines: Vec<&str> = page.lines().filter(|l| !l.trim().is_empty()).collect();
        let mut keys = Vec::new();
        for line in [lines.first(), lines.last()].into_iter().flatten() {
            if lines.len() > 1 {
                keys.extend(key(line));
            }
        }
        keys.dedup();
        keys
    };
    let mut counts = std::collections::HashMap::<String, usize>::new();
    for page in pages.iter() {
        for k in edges(page) {
            *counts.entry(k).or_default() += 1;
        }
    }
    let repeated = |k: &str| counts.get(k).is_some_and(|n| *n >= 3);
    for page in pages.iter_mut() {
        let lines: Vec<&str> = page.lines().collect();
        let first = lines.iter().position(|l| !l.trim().is_empty());
        let last = lines.iter().rposition(|l| !l.trim().is_empty());
        if first == last {
            continue;
        }
        let kept: Vec<&str> = lines
            .iter()
            .enumerate()
            .filter(|(i, l)| {
                !((Some(*i) == first || Some(*i) == last) && key(l).is_some_and(|k| repeated(&k)))
            })
            .map(|(_, l)| *l)
            .collect();
        *page = kept.join("\n").trim().to_string();
    }
}

/// `pdf_extract` emits one `\n` per visual line. A lone `\n` is a soft wrap (joined with a
/// space, or glued back when a hyphenated word is split) unless it is a real paragraph end:
/// the next line opens with a dialogue dash, or the line is well short of the page width and
/// ends a sentence. Runs of two or more `\n` stay paragraph breaks. Returns the reflowed text
/// and its paragraph ends (in chars), consistent with that text.
fn reflow_paragraphs(text: &str) -> (String, Vec<usize>) {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut widths: Vec<usize> = lines
        .iter()
        .map(|line| line.trim().chars().count())
        .filter(|width| *width > 0)
        .collect();
    widths.sort_unstable();
    let typical = widths
        .get(widths.len().saturating_mul(3) / 4)
        .copied()
        .unwrap_or(0) as f64;
    let mut out = String::new();
    let mut ends = Vec::new();
    let mut count = 0usize;
    let push = |out: &mut String, count: &mut usize, piece: &str| {
        out.push_str(piece);
        *count += piece.chars().count();
    };
    for (i, line) in lines.iter().enumerate() {
        let line = line.trim_end_matches('\r');
        push(&mut out, &mut count, line);
        let Some(next) = lines.get(i + 1) else {
            break;
        };
        let current = line.trim_end();
        let next_start = next.trim_start();
        if line.trim().is_empty() || next_start.is_empty() {
            // Part of a blank-line run: keep the separators verbatim.
            if !line.trim().is_empty() && ends.last() != Some(&count) {
                ends.push(count);
            }
            push(&mut out, &mut count, "\n");
            continue;
        }
        let hyphenated = current.ends_with('-')
            && current
                .chars()
                .rev()
                .nth(1)
                .is_some_and(char::is_alphabetic)
            && next_start.chars().next().is_some_and(char::is_lowercase);
        let dialogue = next_start.starts_with('\u{2014}');
        let short_sentence_end = (current.chars().count() as f64) < typical * SHORT_LINE_RATIO
            && current.ends_with(['.', '!', '?', ':', '\u{2026}']);
        if dialogue || short_sentence_end {
            ends.push(count);
            push(&mut out, &mut count, "\n");
        } else if hyphenated {
            out.truncate(out.trim_end().len() - 1);
            count = out.chars().count();
        } else {
            out.truncate(out.trim_end().len());
            count = out.chars().count();
            push(&mut out, &mut count, " ");
            // The soft wrap carried no paragraph end; the trailing space keeps words apart.
        }
    }
    // A blank-line run ends the paragraph before it, handled above; close the final one.
    let total = out.chars().count();
    if ends.last() != Some(&total) {
        ends.push(total);
    }
    (out, ends)
}
fn info(doc: &Document, key: &[u8]) -> Option<String> {
    let value = doc.trailer.get(b"Info").ok()?;
    let dict = super::pdf_outline::dictionary(doc, value).ok()?;
    decode_text_string(dict.get(key).ok()?).ok()
}
pub(super) fn invalid(message: &str) -> IngestionError {
    IngestionError::InvalidInput {
        message: message.into(),
    }
}
fn extraction_error(error: impl std::fmt::Display) -> IngestionError {
    IngestionError::ExtractionFailed {
        message: format!("PDF text extraction failed: {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::{normalize_page, reflow_paragraphs};

    #[test]
    fn ligatures_map_to_letters() {
        assert_eq!(
            normalize_page("of\u{fb01}cial \u{fb02}uxo \u{fb00}\u{fb03}\u{fb04}\u{fb05}\u{fb06}"),
            "official fluxo ffffiffl".to_string() + "stst"
        );
    }

    #[test]
    fn a_dialogue_dash_opens_a_new_paragraph() {
        let (text, ends) = reflow_paragraphs(
            "Ele disse isto e foi embora\n\u{2014} Fala dela.\n\u{2014} Outra fala.",
        );
        assert_eq!(
            text,
            "Ele disse isto e foi embora\n\u{2014} Fala dela.\n\u{2014} Outra fala."
        );
        assert_eq!(ends, vec![27, 40, text.chars().count()]);
    }

    #[test]
    fn hyphen_before_uppercase_keeps_the_hyphen_and_the_blank_run_stays() {
        let (text, ends) = reflow_paragraphs("Rio-\nBranco segue\n\nFim");
        assert_eq!(text, "Rio- Branco segue\n\nFim");
        assert_eq!(ends, vec![17, 22]);
    }
}
