mod epub_chapter_content;
mod epub_package;
mod epub_resources;
use epub_chapter_content::{
    first_heading, hierarchy_indices, html_to_text_projection, toc_levels, toc_title_for,
};
use epub_package::{
    normalized_media_type, parse_package, resolve_resource_path, xml_attr, xml_text, Manifest,
};
use epub_resources::{read_entry, read_resource, EpubReadBudget};

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
    pub level: u32,
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
}

pub fn parse_epub<R: Read + Seek>(reader: R) -> Result<Book, EpubError> {
    parse_epub_with_limits(reader, EpubReadLimits::default())
}

/// Parse a book with an explicit decompressed-read budget.
pub fn parse_epub_with_limits<R: Read + Seek>(
    reader: R,
    limits: EpubReadLimits,
) -> Result<Book, EpubError> {
    let mut budget = EpubReadBudget::new(limits);
    let mut archive = ZipArchive::new(reader)?;
    let container = read_entry(&mut archive, "META-INF/container.xml", &mut budget)?;
    let rootfile =
        xml_attr(&container, b"rootfile", b"full-path").ok_or(EpubError::MissingRootfile)?;
    let opf_dir = Path::new(&rootfile).parent().unwrap_or(Path::new(""));
    let opf = read_entry(&mut archive, &rootfile, &mut budget)?;

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

    let toc = if let Some(href) = nav_href {
        parse_nav(&read_entry(
            &mut archive,
            &resolve_resource_path(opf_dir, &href),
            &mut budget,
        )?)
        .unwrap_or_default()
    } else if let Some(href) = ncx_href {
        parse_ncx(&read_entry(
            &mut archive,
            &resolve_resource_path(opf_dir, &href),
            &mut budget,
        )?)
        .unwrap_or_default()
    } else {
        Vec::new()
    };
    let indices = hierarchy_indices(&toc);
    let levels = toc_levels(&toc);
    let mut chapters = Vec::new();
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
        let html = read_entry(&mut archive, &path, &mut budget)?;
        let (text, paragraph_ends) = html_to_text_projection(&html);
        if text.trim().is_empty() {
            continue;
        }
        let key = href.split('#').next().unwrap_or(&href);
        let index = if let Some(value) = indices.get(key) {
            value.clone()
        } else {
            orphan += 1;
            orphan.to_string()
        };
        let level = levels.get(key).copied().unwrap_or(1);
        let toc_title = toc_title_for(&toc, key);
        chapters.push(Chapter {
            index,
            name: toc_title
                .or_else(|| first_heading(&html))
                .unwrap_or_else(|| format!("Chapter {}", position + 1)),
            source_path: path,
            text,
            paragraph_ends,
            level,
        });
    }
    let (cover, cover_mime) = cover_image(&mut archive, &manifest, opf_dir, &mut budget)?;
    Ok(Book {
        title,
        author,
        language,
        chapters,
        toc,
        cover,
        cover_mime,
    })
}

fn cover_image<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    manifest: &Manifest,
    base: &Path,
    budget: &mut EpubReadBudget,
) -> Result<(Option<Vec<u8>>, Option<String>), EpubError> {
    for (href, media) in manifest.values() {
        let media = media.as_deref().unwrap_or_default().to_ascii_lowercase();
        let name = href.to_ascii_lowercase();
        if media.starts_with("image/") && (name.contains("cover") || name.contains("capa")) {
            let path = resolve_resource_path(base, href);
            let bytes = read_resource(archive, &path, budget)?;
            return Ok((Some(bytes), Some(media.to_string())));
        }
    }
    Ok((None, None))
}

#[cfg(test)]
#[path = "epub/epub_contract_tests.rs"]
mod tests;
