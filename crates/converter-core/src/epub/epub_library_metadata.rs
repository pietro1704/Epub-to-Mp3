//! Library-card metadata: title, author, declared language and cover, read from
//! the container and package document only, without parsing any chapter.
use super::epub_package::{
    local_name, normalized_media_type, resolve_resource_path, xml_attr, xml_text,
};
use super::epub_resources::{read_entry, read_resource, EpubReadBudget};
use super::{EpubError, EpubReadLimits};
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use std::io::{Read, Seek};
use std::path::Path;
use zip::ZipArchive;

/// What a library shelf shows for a book before it is opened.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LibraryMetadata {
    pub title: Option<String>,
    pub author: Option<String>,
    /// The language the package declares, not a detection result.
    pub language: Option<String>,
    pub cover: Option<Vec<u8>>,
    pub cover_mime: Option<String>,
}

/// Read library metadata with the default decompressed-read budget. A missing
/// or over-limit cover leaves `cover` empty instead of failing the shelf card.
pub fn read_library_metadata<R: Read + Seek>(reader: R) -> Result<LibraryMetadata, EpubError> {
    let mut budget = EpubReadBudget::new(EpubReadLimits::default());
    let mut archive = ZipArchive::new(reader)?;
    archive.validate_header_consistency()?;
    let container = read_entry(&mut archive, "META-INF/container.xml", &mut budget)?;
    let rootfile =
        xml_attr(&container, b"rootfile", b"full-path").ok_or(EpubError::MissingRootfile)?;
    let opf = read_entry(&mut archive, &rootfile, &mut budget)?;
    let opf_dir = Path::new(&rootfile).parent().unwrap_or(Path::new(""));
    let present = |value: Option<String>| value.filter(|text| !text.is_empty());
    // The shelf card keeps a book whose cover cannot be read within limits.
    let (cover, cover_mime) =
        cover_image(&mut archive, &opf, opf_dir, &mut budget).unwrap_or((None, None));
    Ok(LibraryMetadata {
        title: present(xml_text(&opf, b"title")),
        author: present(xml_text(&opf, b"creator")),
        language: present(xml_text(&opf, b"language")),
        cover,
        cover_mime,
    })
}

/// Read the package's cover image. A declared cover whose resource is absent
/// yields no cover; read-limit and archive errors are returned to the caller.
pub(super) fn cover_image<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    opf: &str,
    opf_dir: &Path,
    budget: &mut EpubReadBudget,
) -> Result<(Option<Vec<u8>>, Option<String>), EpubError> {
    let Some(item) = cover_item(opf) else {
        return Ok((None, None));
    };
    let path = lexical_archive_path(&resolve_resource_path(opf_dir, &item.href));
    match read_resource(archive, &path, budget) {
        Ok(bytes) if !bytes.is_empty() => Ok((Some(bytes), item.media_type)),
        Ok(_) | Err(EpubError::MissingResource(_)) => Ok((None, None)),
        Err(error) => Err(error),
    }
}

#[derive(Debug, PartialEq, Eq)]
struct ManifestItem {
    id: Option<String>,
    href: String,
    media_type: Option<String>,
    properties: String,
}

impl ManifestItem {
    fn is_image(&self) -> bool {
        self.media_type
            .as_deref()
            .is_some_and(|media| media.starts_with("image/"))
    }
}

/// The cover the package declares, in specification order: the EPUB 3
/// `cover-image` property, then the EPUB 2 `<meta name="cover">` reference,
/// then the first image whose name says it is a cover.
fn cover_item(opf: &str) -> Option<ManifestItem> {
    let (items, cover_id) = scan_package(opf);
    let declared = items.iter().position(|item| {
        item.properties
            .split_whitespace()
            .any(|property| property.eq_ignore_ascii_case("cover-image"))
    });
    let referenced = || {
        let id = cover_id.as_deref()?;
        items
            .iter()
            .position(|item| item.id.as_deref() == Some(id) && item.is_image())
    };
    let named = || {
        items.iter().position(|item| {
            let name = item.href.to_ascii_lowercase();
            item.is_image() && (name.contains("cover") || name.contains("capa"))
        })
    };
    let position = declared.or_else(referenced).or_else(named)?;
    items.into_iter().nth(position)
}

/// Manifest items in document order and the EPUB 2 cover id. Malformed XML
/// ends the scan with what was read so far.
fn scan_package(opf: &str) -> (Vec<ManifestItem>, Option<String>) {
    let mut reader = Reader::from_str(opf);
    let mut items = Vec::new();
    let mut cover_id = None;
    loop {
        match reader.read_event() {
            Ok(Event::Empty(element)) | Ok(Event::Start(element)) => {
                match local_name(element.name().as_ref()) {
                    b"item" => {
                        if let Some(href) = attribute(&element, b"href") {
                            items.push(ManifestItem {
                                id: attribute(&element, b"id"),
                                href,
                                media_type: normalized_media_type(
                                    attribute(&element, b"media-type").as_deref(),
                                ),
                                properties: attribute(&element, b"properties").unwrap_or_default(),
                            });
                        }
                    }
                    b"meta"
                        if cover_id.is_none()
                            && attribute(&element, b"name").as_deref() == Some("cover") =>
                    {
                        cover_id = attribute(&element, b"content");
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    (items, cover_id)
}

/// Fold `.` and `..` segments so a package in a subfolder can reference a
/// sibling folder. Segments never climb above the archive root.
fn lexical_archive_path(path: &str) -> String {
    let mut segments: Vec<&str> = Vec::new();
    for segment in path.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                segments.pop();
            }
            _ => segments.push(segment),
        }
    }
    segments.join("/")
}

fn attribute(element: &BytesStart<'_>, key: &[u8]) -> Option<String> {
    element
        .attributes()
        .flatten()
        .find(|candidate| local_name(candidate.key.as_ref()) == key)
        .and_then(|candidate| {
            candidate
                .unescape_value()
                .ok()
                .map(|value| value.into_owned())
        })
}

#[cfg(test)]
#[path = "epub_library_metadata_tests.rs"]
mod tests;
