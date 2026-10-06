use std::collections::HashMap;
use std::fs::File;
use std::path::Path;

use quick_xml::Reader;
use quick_xml::events::Event;
use zip::ZipArchive;

use crate::{BookStructure, Chapter};

#[derive(Debug)]
pub enum EpubError {
    Io(std::io::Error),
    Zip(zip::result::ZipError),
    Xml(quick_xml::Error),
    MissingContainer,
    MissingPackage,
    MissingSpine,
    InvalidUtf8,
}

impl std::fmt::Display for EpubError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "failed to read EPUB: {error}"),
            Self::Zip(error) => write!(formatter, "invalid EPUB archive: {error}"),
            Self::Xml(error) => write!(formatter, "invalid EPUB XML: {error}"),
            Self::MissingContainer => formatter.write_str("EPUB container.xml is missing"),
            Self::MissingPackage => formatter.write_str("EPUB package document is missing"),
            Self::MissingSpine => formatter.write_str("EPUB spine is missing"),
            Self::InvalidUtf8 => formatter.write_str("EPUB contains invalid UTF-8 text"),
        }
    }
}

impl std::error::Error for EpubError {}

impl From<std::io::Error> for EpubError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<zip::result::ZipError> for EpubError {
    fn from(error: zip::result::ZipError) -> Self {
        Self::Zip(error)
    }
}

impl From<quick_xml::Error> for EpubError {
    fn from(error: quick_xml::Error) -> Self {
        Self::Xml(error)
    }
}

pub fn parse_epub(path: impl AsRef<Path>) -> Result<BookStructure, EpubError> {
    let file = File::open(path)?;
    let mut archive = ZipArchive::new(file)?;
    let container =
        read_entry(&mut archive, "META-INF/container.xml")?.ok_or(EpubError::MissingContainer)?;
    let package_path = parse_package_path(&container)?.ok_or(EpubError::MissingPackage)?;
    let package = read_entry(&mut archive, &package_path)?.ok_or(EpubError::MissingPackage)?;
    let package_dir = Path::new(&package_path)
        .parent()
        .unwrap_or_else(|| Path::new(""));
    let metadata = parse_package(&package)?;
    let chapters = metadata
        .spine
        .iter()
        .enumerate()
        .filter_map(|(position, id)| {
            let href = metadata.manifest.get(id)?;
            let entry = package_dir.join(href).to_string_lossy().replace('\\', "/");
            let content = read_entry(&mut archive, &entry).ok().flatten()?;
            let text = html_text(&content);
            if text.is_empty() {
                return None;
            }
            let title = metadata
                .titles
                .get(id)
                .cloned()
                .unwrap_or_else(|| format!("Chapter {}", position + 1));
            Some(Chapter {
                index: (position + 1).to_string(),
                title,
                text,
            })
        })
        .collect::<Vec<_>>();
    if chapters.is_empty() {
        return Err(EpubError::MissingSpine);
    }
    Ok(BookStructure {
        title: metadata.title,
        author: metadata.author,
        chapters,
    })
}

#[cfg(test)]
mod tests {
    use super::{html_text, parse_package, parse_package_path};

    #[test]
    fn extracts_package_path_and_spine() {
        let container = r#"<container><rootfile full-path="OPS/package.opf"/></container>"#;
        assert_eq!(
            parse_package_path(container).unwrap().as_deref(),
            Some("OPS/package.opf")
        );
        let package = r#"<package><metadata><dc:title>Book</dc:title><dc:creator>Author</dc:creator></metadata><manifest><item id="chapter" href="chapter.xhtml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#;
        let metadata = parse_package(package).unwrap();
        assert_eq!(metadata.title, "Book");
        assert_eq!(metadata.author.as_deref(), Some("Author"));
        assert_eq!(metadata.spine, ["chapter"]);
    }

    #[test]
    fn extracts_narratable_text_from_xhtml() {
        assert_eq!(
            html_text("<h1>Chapter</h1><p>Hello &amp; world.</p>"),
            "Chapter Hello & world."
        );
    }
}

struct PackageMetadata {
    title: String,
    author: Option<String>,
    manifest: HashMap<String, String>,
    titles: HashMap<String, String>,
    spine: Vec<String>,
}

fn read_entry<R: std::io::Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
) -> Result<Option<String>, EpubError> {
    let Ok(mut entry) = archive.by_name(name) else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut entry, &mut bytes)?;
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| EpubError::InvalidUtf8)
}

fn parse_package_path(xml: &str) -> Result<Option<String>, EpubError> {
    let mut reader = Reader::from_str(xml);
    let mut buffer = Vec::new();
    loop {
        match reader.read_event_into(&mut buffer)? {
            Event::Start(event) | Event::Empty(event) if event.name().as_ref() == b"rootfile" => {
                for attribute in event.attributes().flatten() {
                    if attribute.key.as_ref() == b"full-path" {
                        return Ok(Some(
                            attribute
                                .unescape_value()
                                .map_err(quick_xml::Error::from)?
                                .into_owned(),
                        ));
                    }
                }
            }
            Event::Eof => return Ok(None),
            _ => {}
        }
        buffer.clear();
    }
}

fn parse_package(xml: &str) -> Result<PackageMetadata, EpubError> {
    let mut reader = Reader::from_str(xml);
    let mut buffer = Vec::new();
    let mut metadata = PackageMetadata {
        title: "Untitled".to_owned(),
        author: None,
        manifest: HashMap::new(),
        titles: HashMap::new(),
        spine: Vec::new(),
    };
    let mut current: Option<Vec<u8>> = None;
    loop {
        match reader.read_event_into(&mut buffer)? {
            Event::Start(event) | Event::Empty(event) => {
                let name = event.name().as_ref().to_vec();
                if name == b"item" {
                    let mut id = None;
                    let mut href = None;
                    for attribute in event.attributes().flatten() {
                        match attribute.key.as_ref() {
                            b"id" => id = Some(attribute.unescape_value()?.into_owned()),
                            b"href" => href = Some(attribute.unescape_value()?.into_owned()),
                            _ => {}
                        }
                    }
                    if let (Some(id), Some(href)) = (id, href) {
                        metadata.manifest.insert(id, href);
                    }
                } else if name == b"itemref" {
                    for attribute in event.attributes().flatten() {
                        if attribute.key.as_ref() == b"idref" {
                            metadata
                                .spine
                                .push(attribute.unescape_value()?.into_owned());
                        }
                    }
                } else if name == b"dc:title"
                    || name == b"title"
                    || name == b"dc:creator"
                    || name == b"creator"
                {
                    current = Some(name);
                }
            }
            Event::Text(text) if current.is_some() => {
                let value = text.unescape()?.into_owned();
                match current.take().as_deref() {
                    Some(b"dc:title") | Some(b"title") => metadata.title = value,
                    Some(b"dc:creator") | Some(b"creator") => metadata.author = Some(value),
                    _ => {}
                }
            }
            Event::End(_) => current = None,
            Event::Eof => break,
            _ => {}
        }
        buffer.clear();
    }
    metadata.titles = metadata
        .manifest
        .keys()
        .map(|id| (id.clone(), id.clone()))
        .collect();
    Ok(metadata)
}

fn html_text(html: &str) -> String {
    let mut reader = Reader::from_str(html);
    let mut buffer = Vec::new();
    let mut output = String::new();
    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Text(text)) => {
                if let Ok(value) = text.unescape() {
                    output.push_str(value.trim());
                    output.push(' ');
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buffer.clear();
    }
    output.split_whitespace().collect::<Vec<_>>().join(" ")
}
