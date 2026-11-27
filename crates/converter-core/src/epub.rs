mod epub_chapter_content;
mod epub_footnotes;
mod epub_library_metadata;
mod epub_package;
mod epub_resources;
pub mod footnote_narration;
use epub_chapter_content::{
    first_heading, hierarchy_indices, html_to_text_projection, toc_levels, toc_title_for,
};
pub use epub_footnotes::Footnote;
pub use epub_library_metadata::{read_library_metadata, LibraryMetadata};
use epub_package::{
    normalized_media_type, parse_package, resolve_resource_path, xml_attr, xml_text,
};
use epub_resources::{read_entry, EpubReadBudget};

use std::io::{Read, Seek};
use std::path::Path;

use thiserror::Error;
use zip::ZipArchive;

use crate::toc::{parse_nav, parse_ncx, TocItem};

#[derive(Debug, Error)]
pub enum EpubError {
    #[error("failed to open EPUB: {0}")]
    Open(#[from] std::io::Error),
    #[error("invalid EPUB archive: {0}")]
    Archive(#[from] zip::result::ZipError),
    #[error("malformed EPUB XML in {path}: {source}")]
    Xml {
        path: String,
        source: quick_xml::Error,
    },
    #[error("EPUB container.xml is missing the rootfile path")]
    MissingRootfile,
    #[error("EPUB OPF is missing a spine")]
    MissingSpine,
    #[error("EPUB resource not found: {0}")]
    MissingResource(String),
    #[error("EPUB resource exceeds read limit of {limit} bytes: {path}")]
    ResourceReadLimit { path: String, limit: u64 },
    #[error("EPUB total read limit of {limit} bytes exceeded at: {path}")]
    TotalReadLimit { path: String, limit: u64 },
    #[error("EPUB document exceeds {kind} limit of {limit}: {path}")]
    StructureLimit {
        path: String,
        kind: &'static str,
        limit: usize,
    },
    #[error("Unsafe reader document structure in {path}: {reason}")]
    ReaderStructure { path: String, reason: &'static str },
}

/// Limits decompressed bytes read, including metadata, navigation and cover.
/// Repeated reads count again. These limits do not bound total process memory.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EpubReadLimits {
    pub max_resource_bytes: u64,
    pub max_total_bytes: u64,
}

impl Default for EpubReadLimits {
    fn default() -> Self {
        Self {
            max_resource_bytes: 32 * 1024 * 1024,
            max_total_bytes: 256 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chapter {
    pub index: String,
    pub name: String,
    pub source_path: String,
    pub text: String,
    /// Paragraph ends on the unchanged normalized Unicode-scalar text axis.
    pub paragraph_ends: Vec<usize>,
    /// Heading ends on the same unchanged normalized Unicode-scalar axis.
    pub heading_ends: Vec<usize>,
    pub level: u32,
    /// Plain-text bodies of the notes this chapter links to; empty when none.
    pub footnotes: Vec<Footnote>,
    /// Where each note reference sits on the text axis, for narration; empty when none.
    pub note_marks: Vec<NoteMark>,
    /// TOC fragment ids of this chapter's file with their scalar offset on the same text axis
    /// (empty marker elements included); ids missing from the markup are omitted.
    pub anchors: Vec<(String, usize)>,
}

/// One footnote reference placed on the chapter text axis (additive; the axis itself is unchanged).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteMark {
    /// Scalar offset right after the reference label.
    pub reference_end: usize,
    /// The reference label shown in the text ("1"), when there is one.
    pub label: Option<String>,
    /// The note body as plain text.
    pub text: String,
    /// Scalar range of the body inside this chapter's text, when it lives in the same
    /// document (so narration reads it at the reference instead of at the chapter end).
    pub body: Option<std::ops::Range<usize>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Book {
    pub title: String,
    pub author: String,
    pub language: Option<String>,
    pub chapters: Vec<Chapter>,
    pub toc: Vec<TocItem>,
    pub cover: Option<Vec<u8>>,
    pub cover_mime: Option<String>,
    /// Source pages left out of narration because they have no selectable text (PDF only).
    pub skipped_pages: usize,
    /// Spine documents left out of narration, with the reason (never silent).
    pub skipped_documents: Vec<SkippedDocument>,
}

/// A spine document the parser did not turn into a chapter.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SkippedDocument {
    pub path: String,
    /// `TOC_DOCUMENT` (navigation or printed contents list) or `EMPTY_DOCUMENT` (no text).
    pub reason: &'static str,
}

pub fn parse_epub<R: Read + Seek>(reader: R) -> Result<Book, EpubError> {
    parse_epub_with_limits(reader, EpubReadLimits::default())
}

/// Parse a book with an explicit decompressed-read budget.
pub fn parse_epub_with_limits<R: Read + Seek>(
    reader: R,
    limits: EpubReadLimits,
) -> Result<Book, EpubError> {
    parse_epub_document(reader, limits, false)
}

/// Reader inspection retains image-only spine items; the conversion API above
/// keeps its existing text-only behavior. TOC identity still has one owner.
pub(crate) fn parse_epub_for_reader<R: Read + Seek>(
    reader: R,
    limits: EpubReadLimits,
) -> Result<Book, EpubError> {
    parse_epub_document(reader, limits, true)
}

fn parse_epub_document<R: Read + Seek>(
    reader: R,
    limits: EpubReadLimits,
    reader_mode: bool,
) -> Result<Book, EpubError> {
    let mut budget = EpubReadBudget::new(limits);
    let mut archive = ZipArchive::new(reader)?;
    // Reject conflicting resource identities before trusting the central directory.
    archive.validate_header_consistency()?;
    let container = read_document(
        &mut archive,
        "META-INF/container.xml",
        &mut budget,
        reader_mode,
    )?;
    let rootfile =
        xml_attr(&container, b"rootfile", b"full-path").ok_or(EpubError::MissingRootfile)?;
    let opf_dir = Path::new(&rootfile).parent().unwrap_or(Path::new(""));
    let opf = read_document(&mut archive, &rootfile, &mut budget, reader_mode)?;

    let title = xml_text(&opf, b"title").unwrap_or_default();
    let author = xml_text(&opf, b"creator").unwrap_or_default();
    let language = xml_text(&opf, b"language");
    let (manifest, spine, ncx_href, nav_href) = parse_package(&opf, &rootfile)?;
    let nav_href = nav_href.or_else(|| {
        manifest
            .values()
            .find(|(href, media_type)| {
                normalized_media_type(media_type.as_deref()).as_deref()
                    == Some("application/xhtml+xml")
                    && href
                        .rsplit('/')
                        .next()
                        .unwrap_or_default()
                        .eq_ignore_ascii_case("nav.xhtml")
            })
            .map(|(href, _)| href.clone())
    });
    let ncx_href = manifest
        .values()
        .find(|(candidate, media_type)| {
            ncx_href.as_deref() == Some(candidate.as_str())
                || normalized_media_type(media_type.as_deref()).as_deref()
                    == Some("application/x-dtbncx+xml")
        })
        .map(|(candidate, _)| candidate.clone());

    let nav_path = nav_href
        .as_ref()
        .map(|href| resolve_resource_path(opf_dir, href));
    let toc = if let Some(href) = nav_href {
        parse_nav(&read_document(
            &mut archive,
            &resolve_resource_path(opf_dir, &href),
            &mut budget,
            reader_mode,
        )?)
        .unwrap_or_default()
    } else if let Some(href) = ncx_href {
        parse_ncx(&read_document(
            &mut archive,
            &resolve_resource_path(opf_dir, &href),
            &mut budget,
            reader_mode,
        )?)
        .unwrap_or_default()
    } else {
        Vec::new()
    };
    let indices = hierarchy_indices(&toc);
    let levels = toc_levels(&toc);
    let mut chapters = Vec::new();
    // Notes are optional, so they read from their own budget and never starve the book.
    let mut footnote_budget = EpubReadBudget::new(limits);
    let mut footnote_targets = epub_footnotes::FootnoteTargets::default();
    let mut markup_language = None;
    let mut skipped_documents: Vec<SkippedDocument> = Vec::new();
    let mut orphan = indices
        .values()
        .filter_map(|v| v.parse::<u32>().ok())
        .max()
        .unwrap_or(0);
    for (position, id) in spine.iter().enumerate() {
        let (href, _media_type) = manifest
            .get(id)
            .ok_or_else(|| EpubError::MissingResource(id.clone()))?
            .clone();
        let path = resolve_resource_path(opf_dir, &href);
        let html = read_document(&mut archive, &path, &mut budget, reader_mode)?;
        // The navigation document lists the book; narrating it would read the contents aloud.
        if nav_path.as_deref() == Some(path.as_str()) || is_toc_document(&html) {
            skipped_documents.push(SkippedDocument {
                path: path.clone(),
                reason: "TOC_DOCUMENT",
            });
            continue;
        }
        let (text, paragraph_ends, heading_ends) = html_to_text_projection(&html);
        // A generated title page often carries the tool's language, not the book's.
        let title_page = href.to_ascii_lowercase().contains("titlepage");
        if markup_language.is_none() && !title_page && !text.trim().is_empty() {
            markup_language = crate::language::markup_language(&html);
        }
        if text.trim().is_empty() && !reader_mode {
            skipped_documents.push(SkippedDocument {
                path: path.clone(),
                reason: "EMPTY_DOCUMENT",
            });
            continue;
        }
        let key = href.split('#').next().unwrap_or(&href);
        let index = if let Some(value) = indices.get(key) {
            value.clone()
        } else if reader_mode && text.trim().is_empty() {
            // TOC roots start at 1. Reserve root 0 for reader-only spine items
            // so retaining illustrations cannot renumber convertible chapters.
            format!("0.{}", position + 1)
        } else {
            orphan += 1;
            orphan.to_string()
        };
        // With a TOC, a spine file it never mentions continues the chapter before it.
        let continues = !indices.is_empty()
            && !indices.contains_key(key)
            && !text.trim().is_empty()
            && chapters.last().is_some_and(|previous: &Chapter| {
                !previous.text.trim().is_empty() && same_logical_file(&previous.source_path, &path)
            });
        let level = levels.get(key).copied().unwrap_or(1);
        let toc_title = toc_title_for(&toc, key);
        let found = epub_footnotes::chapter_footnotes_with_targets(
            &html,
            &path,
            &mut archive,
            &mut footnote_budget,
            &mut footnote_targets,
        );
        let note_marks = note_marks(&html, &found);
        let anchors =
            epub_chapter_content::anchor_positions(&html, &crate::toc::toc_fragments(&toc, &path));
        let footnotes: Vec<_> = found.into_iter().map(|(note, _)| note).collect();
        if continues {
            let previous: &mut Chapter = chapters.last_mut().expect("checked above");
            let base = previous.text.chars().count() + 1;
            previous.text.push(' ');
            previous.text.push_str(&text);
            previous
                .paragraph_ends
                .extend(paragraph_ends.iter().map(|end| end + base));
            previous
                .heading_ends
                .extend(heading_ends.iter().map(|end| end + base));
            previous
                .note_marks
                .extend(note_marks.into_iter().map(|mut mark| {
                    mark.reference_end += base;
                    mark.body = mark.body.map(|body| body.start + base..body.end + base);
                    mark
                }));
            previous
                .anchors
                .extend(anchors.into_iter().map(|(id, offset)| (id, offset + base)));
            previous.footnotes.extend(footnotes);
            continue;
        }
        chapters.push(Chapter {
            index,
            name: toc_title
                .or_else(|| first_heading(&html))
                .unwrap_or_else(|| format!("Chapter {}", position + 1)),
            source_path: path,
            text,
            paragraph_ends,
            heading_ends,
            level,
            footnotes,
            note_marks,
            anchors,
        });
    }
    let (cover, cover_mime) =
        epub_library_metadata::cover_image(&mut archive, &opf, opf_dir, &mut budget)?;
    Ok(Book {
        title,
        author,
        // The package declaration wins; markup only fills a missing or invalid one.
        language: language
            .map(|value| value.trim().replace('_', "-"))
            .filter(|value| crate::language::valid_tag(value) && !value.eq_ignore_ascii_case("und"))
            .or(markup_language),
        chapters,
        toc,
        cover,
        cover_mime,
        skipped_pages: 0,
        skipped_documents,
    })
}

/// `chapter_split_001.xhtml` and `chapter2.xhtml` are parts of `chapter_split_000.xhtml` and
/// `chapter.xhtml`; unrelated files (promotional pages, copyright) are not.
fn same_logical_file(previous: &str, next: &str) -> bool {
    fn base(path: &str) -> String {
        let name = path.rsplit('/').next().unwrap_or(path);
        let stem = name.rsplit_once('.').map_or(name, |(stem, _)| stem);
        if let Some((head, tail)) = stem.rsplit_once("_split_") {
            if !tail.is_empty() && tail.bytes().all(|b| b.is_ascii_digit()) {
                return head.to_owned();
            }
        }
        let digits = stem.bytes().rev().take_while(u8::is_ascii_digit).count();
        let head = &stem[..stem.len() - digits];
        let head = head.strip_suffix(['-', '_']).unwrap_or(head);
        if (1..=2).contains(&digits) && !head.is_empty() {
            head.to_owned()
        } else {
            stem.to_owned()
        }
    }
    base(previous) == base(next)
}

/// True for an EPUB 3 navigation document or any page that is only the contents list.
fn is_toc_document(html: &str) -> bool {
    let lower = html.to_ascii_lowercase();
    lower.contains("epub:type=\"toc\"") || lower.contains("role=\"doc-toc\"")
}

/// Join each reference position with the note body it links to (by link fragment).
fn note_marks(html: &str, found: &[(Footnote, String)]) -> Vec<NoteMark> {
    if found.is_empty() {
        return Vec::new();
    }
    epub_chapter_content::note_positions(html)
        .into_iter()
        .filter_map(|reference| {
            let (note, _) = found
                .iter()
                .find(|(_, fragment)| *fragment == reference.target)?;
            Some(NoteMark {
                reference_end: reference.end,
                label: note.number.clone(),
                text: note.text.clone(),
                body: reference.body,
            })
        })
        .collect()
}

fn read_document<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    path: &str,
    budget: &mut EpubReadBudget,
    reader_mode: bool,
) -> Result<String, EpubError> {
    let source = read_entry(archive, path, budget)?;
    if reader_mode {
        // Guard recursive TOC consumers before building their trees. HTML5
        // parsing/sanitisation applies its own independent depth/node guards.
        let mut parser = quick_xml::Reader::from_str(&source);
        parser.config_mut().check_end_names = false;
        let mut depth = 0usize;
        let mut nodes = 0usize;
        let mut ncx_points = 0usize;
        let mut ncx_label = false;
        loop {
            match parser.read_event() {
                Ok(quick_xml::events::Event::Start(event)) => {
                    nodes += 1;
                    let name =
                        String::from_utf8_lossy(event.local_name().as_ref()).to_ascii_lowercase();
                    // The legacy NCX parser consumes one event for a label;
                    // nested elements there must not alter its navPoint stack.
                    if ncx_label {
                        return Err(EpubError::ReaderStructure {
                            path: path.into(),
                            reason: "NCX labels must contain text only",
                        });
                    }
                    if name == "navpoint" {
                        ncx_points += 1;
                    }
                    if name == "text" && ncx_points > 0 {
                        ncx_label = true;
                    }
                    if !reader_void_element(&name) {
                        depth += 1;
                    }
                }
                Ok(quick_xml::events::Event::Empty(_)) => nodes += 1,
                Ok(quick_xml::events::Event::End(event)) => {
                    let name =
                        String::from_utf8_lossy(event.local_name().as_ref()).to_ascii_lowercase();
                    // Paired void tags must not drain the depth contributed by
                    // enclosing li/navPoint nodes before their recursive parser.
                    if !reader_void_element(&name) {
                        depth = depth.saturating_sub(1);
                    }
                    if name == "text" {
                        ncx_label = false;
                    }
                    if name == "navpoint" {
                        ncx_points = ncx_points.saturating_sub(1);
                    }
                }
                Ok(quick_xml::events::Event::Eof) | Err(_) => break,
                _ => {}
            }
            if depth > 128 || nodes > 50_000 {
                return Err(EpubError::StructureLimit {
                    path: path.into(),
                    kind: if depth > 128 { "depth" } else { "nodes" },
                    limit: if depth > 128 { 128 } else { 50_000 },
                });
            }
        }
    }
    Ok(source)
}

fn reader_void_element(name: &str) -> bool {
    matches!(
        name,
        "area"
            | "base"
            | "br"
            | "col"
            | "embed"
            | "hr"
            | "img"
            | "input"
            | "link"
            | "meta"
            | "param"
            | "source"
            | "track"
            | "wbr"
    )
}

#[cfg(test)]
#[path = "epub/epub_contract_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "epub/epub_footnotes_tests.rs"]
mod footnote_tests;

#[cfg(test)]
#[path = "epub/epub_spine_toc_tests.rs"]
mod spine_toc_tests;
