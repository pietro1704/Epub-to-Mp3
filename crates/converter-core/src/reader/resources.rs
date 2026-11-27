//! EPUB metadata comes from the existing parser; supplemental reads share a
//! second bounded budget. Each half is 32 MiB, so total decompression is 64 MiB.
mod raster;
use super::{
    bounded, css, markup, ChapterAnchor, ReaderBook, ReaderError, Result, SourceChapter,
    MAX_CHAPTER_BYTES, MAX_CSS_BYTES, MAX_EPUB_BYTES, MAX_OUTPUT_BYTES,
};
use crate::epub::{parse_epub_for_reader, EpubReadLimits};
use base64::{engine::general_purpose::STANDARD, Engine};
use percent_encoding::percent_decode_str;
pub(super) use raster::safe_data_image;
use scraper::{ElementRef, Html};
use std::{
    collections::{BTreeMap, HashSet},
    io::{Cursor, Read},
    path::Path,
};
use zip::ZipArchive;

const RESOURCE_BYTES: usize = 8 * 1024 * 1024;
const READ_BUDGET: usize = 32 * 1024 * 1024;
const MAX_IMAGES: usize = 128;

struct Resources<'a> {
    archive: ZipArchive<Cursor<&'a [u8]>>,
    remaining: usize,
}

impl Resources<'_> {
    fn read(&mut self, path: &str, limit: usize) -> Result<Option<Vec<u8>>> {
        let Some(index) = crate::zip_names::member_index(&self.archive, path)? else {
            return Ok(None);
        };
        let file = self.archive.by_index(index)?;
        let limit = limit.min(RESOURCE_BYTES);
        bounded(
            file.size().try_into().unwrap_or(usize::MAX),
            limit,
            "resource bytes",
        )?;
        bounded(
            file.size().try_into().unwrap_or(usize::MAX),
            self.remaining,
            "supplemental read budget",
        )?;
        let mut bytes = Vec::new();
        file.take(limit.min(self.remaining) as u64 + 1)
            .read_to_end(&mut bytes)?;
        bounded(bytes.len(), limit, "resource bytes")?;
        bounded(bytes.len(), self.remaining, "supplemental read budget")?;
        self.remaining -= bytes.len();
        Ok(Some(bytes))
    }
}

pub(super) fn inspect(bytes: &[u8]) -> Result<ReaderBook> {
    bounded(bytes.len(), MAX_EPUB_BYTES, "EPUB bytes")?;
    let mut archive = ZipArchive::new(Cursor::new(bytes))?;
    archive.validate_header_consistency()?;
    bounded(archive.len(), 4096, "archive entries")?;
    // The existing parser retains ownership of TOC hierarchy and chapter labels.
    let book = parse_epub_for_reader(
        Cursor::new(bytes),
        EpubReadLimits {
            max_resource_bytes: RESOURCE_BYTES as u64,
            max_total_bytes: READ_BUDGET as u64,
        },
    )?;
    bounded(book.chapters.len(), 2048, "chapters")?;
    let mut identities = HashSet::new();
    let mut paths = BTreeMap::new();
    for chapter in &book.chapters {
        if !markup::valid_index(&chapter.index) || !identities.insert(chapter.index.clone()) {
            return Err(ReaderError::Invalid(
                "Chapter indices must be unique hierarchical strings".into(),
            ));
        }
        let path = normalize(&chapter.source_path)
            .ok_or_else(|| ReaderError::Invalid("Invalid chapter source path".into()))?;
        paths.entry(path).or_insert_with(|| chapter.index.clone());
    }
    let mut resources = Resources {
        archive,
        remaining: READ_BUDGET,
    };
    let mut chapters = Vec::new();
    let mut output_bytes = 0;
    for chapter in book.chapters {
        let source = resources
            .read(&chapter.source_path, MAX_CHAPTER_BYTES)?
            .ok_or_else(|| {
                ReaderError::Invalid(format!("Missing chapter: {}", chapter.source_path))
            })?;
        let source = String::from_utf8(source)
            .map_err(|_| ReaderError::Invalid("Chapter is not UTF-8".into()))?;
        let mut nodes = markup::parse(&source)?;
        let stylesheet = source_styles(&source, &chapter.source_path, &mut resources)?;
        let mut images = 0;
        resolve_nodes(
            &mut nodes,
            &chapter.source_path,
            &paths,
            &mut resources,
            &mut images,
        )?;
        let mut stylesheet = css::stylesheet(&stylesheet)?;
        let mut inline_sequence = 0;
        markup::clean(&mut nodes, &mut stylesheet, &mut inline_sequence)?;
        let nodes = super::text_axis::normalize(nodes);
        let html = markup::serialize(&nodes);
        let mut text = String::new();
        markup::text(&nodes, &mut text);
        let wanted = crate::toc::toc_fragments(&book.toc, &chapter.source_path);
        let anchors = markup::anchors(&nodes, &wanted)
            .into_iter()
            .map(|(id, offset)| ChapterAnchor { id, offset })
            .collect();
        bounded(
            html.len(),
            MAX_CHAPTER_BYTES,
            "resolved chapter markup bytes",
        )?;
        output_bytes += html.len() + text.len() + stylesheet.len();
        bounded(output_bytes, MAX_OUTPUT_BYTES, "book content bytes")?;
        chapters.push(SourceChapter {
            index: chapter.index,
            name: chapter.name,
            source_path: chapter.source_path,
            level: chapter.level,
            text,
            html,
            css: stylesheet,
            anchors,
        });
    }
    Ok(ReaderBook {
        book_title: book.title,
        book_author: book.author,
        language: book.language,
        chapters,
    })
}

fn source_styles(source: &str, path: &str, resources: &mut Resources<'_>) -> Result<String> {
    let parsed = Html::parse_document(source);
    let mut styles = String::new();
    for node in parsed
        .tree
        .root()
        .descendants()
        .filter_map(ElementRef::wrap)
    {
        if node.value().name() == "style" {
            styles.extend(node.text());
            styles.push('\n');
        }
        if node.value().name() == "link"
            && node.value().attr("rel").is_some_and(|rel| {
                rel.split_whitespace()
                    .any(|v| v.eq_ignore_ascii_case("stylesheet"))
            })
        {
            if let Some((resource, _)) = node
                .value()
                .attr("href")
                .and_then(|href| resolve_local(path, href))
            {
                if let Some(bytes) = resources.read(&resource, MAX_CSS_BYTES)? {
                    if let Ok(style) = String::from_utf8(bytes) {
                        styles.push_str(&style);
                        styles.push('\n');
                    }
                }
            }
        }
        bounded(styles.len(), MAX_CSS_BYTES, "chapter CSS bytes")?;
    }
    Ok(styles)
}

fn resolve_nodes(
    nodes: &mut [markup::Node],
    source: &str,
    paths: &BTreeMap<String, String>,
    resources: &mut Resources<'_>,
    images: &mut usize,
) -> Result<()> {
    for node in nodes {
        let markup::Node::Element {
            tag,
            attrs,
            children,
        } = node
        else {
            continue;
        };
        // Only this resolution pass can introduce book-relative navigation.
        attrs.remove("data-reader-chapter");
        attrs.remove("data-reader-fragment");
        if tag == "a" {
            if let Some((path, fragment)) = attrs
                .get("href")
                .and_then(|href| resolve_local(source, href))
            {
                if let Some(index) = paths.get(&path) {
                    attrs.insert("data-reader-chapter".into(), index.clone());
                    attrs.insert("data-reader-fragment".into(), fragment);
                }
            }
        }
        if tag == "img" {
            *images += 1;
            bounded(*images, MAX_IMAGES, "chapter images")?;
            if let Some((path, _)) = attrs
                .get("src")
                .and_then(|href| resolve_local(source, href))
            {
                if let Some(bytes) = resources.read(&path, raster::MAX_IMAGE_BYTES)? {
                    if let Some(mime) = raster::mime(&bytes) {
                        attrs.insert(
                            "src".into(),
                            format!("data:{mime};base64,{}", STANDARD.encode(bytes)),
                        );
                    }
                }
            }
        }
        resolve_nodes(children, source, paths, resources, images)?;
    }
    Ok(())
}

fn normalize(path: &str) -> Option<String> {
    if path.starts_with('/')
        || path.contains(['\\', ':', '?', '#'])
        || path.chars().any(char::is_control)
    {
        return None;
    }
    let mut components = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                components.pop()?;
            }
            _ => components.push(part),
        }
    }
    (!components.is_empty()).then(|| components.join("/"))
}

pub(super) fn resolve_local(source: &str, href: &str) -> Option<(String, String)> {
    let href = href.trim();
    if href.starts_with('/')
        || href.contains(['\\', ':', '?'])
        || href.chars().any(char::is_control)
    {
        return None;
    }
    let (path, fragment) = href.split_once('#').unwrap_or((href, ""));
    let path = percent_decode_str(path).decode_utf8().ok()?;
    if path.starts_with('/') {
        return None;
    }
    let fragment = percent_decode_str(fragment)
        .decode_utf8()
        .ok()?
        .into_owned();
    if fragment.len() > 2048 || fragment.chars().any(char::is_control) {
        return None;
    }
    let path = if path.is_empty() {
        normalize(source)?
    } else {
        let parent = Path::new(source).parent()?.to_str()?;
        normalize(&if parent.is_empty() {
            path.into_owned()
        } else {
            format!("{parent}/{path}")
        })?
    };
    Some((path, fragment))
}
