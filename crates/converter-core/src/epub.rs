use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek};
use std::path::Path;

use percent_encoding::percent_decode_str;
use quick_xml::events::Event;
use quick_xml::Reader;
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
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chapter {
    pub index: String,
    pub name: String,
    pub source_path: String,
    pub text: String,
    pub level: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Book {
    pub title: String,
    pub author: String,
    pub language: Option<String>,
    pub chapters: Vec<Chapter>,
    pub toc: Vec<TocItem>,
}

type Manifest = HashMap<String, (String, Option<String>)>;
type PackageParts = (Manifest, Vec<String>, Option<String>, Option<String>);

pub fn parse_epub<R: Read + Seek>(reader: R) -> Result<Book, EpubError> {
    let mut archive = ZipArchive::new(reader)?;
    let container = read_entry(&mut archive, "META-INF/container.xml")?;
    let rootfile =
        xml_attr(&container, b"rootfile", b"full-path").ok_or(EpubError::MissingRootfile)?;
    let opf_dir = Path::new(&rootfile).parent().unwrap_or(Path::new(""));
    let opf = read_entry(&mut archive, &rootfile)?;

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
        )?)
        .unwrap_or_default()
    } else if let Some(href) = ncx_href {
        parse_ncx(&read_entry(
            &mut archive,
            &resolve_resource_path(opf_dir, &href),
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
        let (href, name) = manifest
            .get(id)
            .ok_or_else(|| EpubError::MissingResource(id.clone()))?
            .clone();
        let path = resolve_resource_path(opf_dir, &href);
        let html = read_entry(&mut archive, &path)?;
        let text = html_to_text(&html);
        if text.trim().is_empty() {
            continue;
        }
        let key = href.split('#').next().unwrap_or(&href);
        let is_boilerplate = text
            .to_ascii_lowercase()
            .contains("dados de copyright sobre a obra");
        if is_boilerplate && position < 3 {
            continue;
        }
        let normalized = text.trim().to_ascii_lowercase();
        if position < 5
            && (normalized.starts_with("sumário ")
                || normalized.starts_with("sumario ")
                || normalized == "sumário"
                || normalized == "sumario")
        {
            continue;
        }
        if position < 10 {
            let editorial = normalized.contains("capa")
                || normalized.contains("folha de rosto")
                || normalized.contains("créditos")
                || normalized.contains("creditos")
                || normalized.contains("copyright");
            if editorial {
                continue;
            }
        }
        let index = if let Some(value) = indices.get(key) {
            value.clone()
        } else {
            orphan += 1;
            orphan.to_string()
        };
        let level = levels.get(key).copied().unwrap_or(1);
        chapters.push(Chapter {
            index,
            name: name.unwrap_or_else(|| {
                first_heading(&html).unwrap_or_else(|| format!("Chapter {}", position + 1))
            }),
            source_path: path,
            text,
            level,
        });
    }
    Ok(Book {
        title,
        author,
        language,
        chapters,
        toc,
    })
}

fn parse_package(xml: &str, _path: &str) -> Result<PackageParts, EpubError> {
    let mut r = Reader::from_str(xml);
    r.config_mut().trim_text(true);
    let mut manifest = HashMap::new();
    let mut spine = Vec::new();
    let mut ncx = None;
    let mut nav = None;
    let mut in_manifest = false;
    let mut in_spine = false;
    loop {
        match r.read_event() {
            Ok(Event::Start(e)) if local_name(e.name().as_ref()) == b"manifest" => {
                in_manifest = true
            }
            Ok(Event::End(e)) if local_name(e.name().as_ref()) == b"manifest" => {
                in_manifest = false
            }
            Ok(Event::Start(e)) if local_name(e.name().as_ref()) == b"spine" => {
                in_spine = true;
                if let Some(v) = attr(&e, b"toc") {
                    ncx = Some(v);
                }
            }
            Ok(Event::End(e)) if local_name(e.name().as_ref()) == b"spine" => in_spine = false,
            Ok(Event::Empty(e)) | Ok(Event::Start(e))
                if local_name(e.name().as_ref()) == b"item" && in_manifest =>
            {
                if let Some(id) = attr(&e, b"id") {
                    let href = attr(&e, b"href").unwrap_or_default();
                    let props = attr(&e, b"properties").unwrap_or_default();
                    if props
                        .split_whitespace()
                        .any(|p| p.eq_ignore_ascii_case("nav"))
                    {
                        nav = Some(href.clone());
                    }
                    if attr(&e, b"media-type")
                        .as_deref()
                        .map(|value| value.eq_ignore_ascii_case("application/x-dtbncx+xml"))
                        .unwrap_or(false)
                    {
                        ncx = Some(href.clone());
                    }
                    manifest.insert(id, (href, attr(&e, b"media-type")));
                }
            }
            Ok(Event::Empty(e)) if local_name(e.name().as_ref()) == b"itemref" && in_spine => {
                if let Some(id) = attr(&e, b"idref") {
                    spine.push(id);
                }
            }
            Ok(Event::Eof) => break,
            Err(source) => {
                return Err(EpubError::Xml {
                    path: _path.into(),
                    source,
                })
            }
            _ => {}
        }
    }
    if spine.is_empty() {
        return Err(EpubError::MissingSpine);
    }
    Ok((manifest, spine, ncx, nav))
}

fn read_entry<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    path: &str,
) -> Result<String, EpubError> {
    let mut f = archive
        .by_name(path)
        .map_err(|_| EpubError::MissingResource(path.into()))?;
    let mut s = String::new();
    f.read_to_string(&mut s)?;
    Ok(s)
}
fn resolve_resource_path(base: &Path, href: &str) -> String {
    let href = href.split('#').next().unwrap_or(href);
    let href = percent_decode_str(href).decode_utf8_lossy();
    let href_path = Path::new(href.as_ref());
    let path = if href_path.starts_with(base) {
        href_path.to_path_buf()
    } else {
        base.join(href_path)
    };
    path.to_string_lossy().replace('\\', "/")
}
fn attr(e: &quick_xml::events::BytesStart<'_>, key: &[u8]) -> Option<String> {
    e.attributes()
        .flatten()
        .find(|a| local_name(a.key.as_ref()) == key)
        .and_then(|a| String::from_utf8(a.value.into_owned()).ok())
}

fn local_name(name: &[u8]) -> &[u8] {
    name.rsplit(|byte| *byte == b':').next().unwrap_or(name)
}

fn normalized_media_type(value: Option<&str>) -> Option<String> {
    value
        .and_then(|raw| raw.split(';').next())
        .map(|raw| raw.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
}

fn xml_attr(xml: &str, element: &[u8], key: &[u8]) -> Option<String> {
    let mut r = Reader::from_str(xml);
    loop {
        match r.read_event().ok()? {
            Event::Empty(e) | Event::Start(e) if local_name(e.name().as_ref()) == element => {
                return attr(&e, key)
            }
            Event::Eof => return None,
            _ => {}
        }
    }
}
fn xml_text(xml: &str, wanted: &[u8]) -> Option<String> {
    let mut r = Reader::from_str(xml);
    let mut on = false;
    let mut out = String::new();
    loop {
        match r.read_event().ok()? {
            Event::Start(e) if local_name(e.name().as_ref()) == wanted => on = true,
            Event::Start(_) if on => {}
            Event::Text(e) if on => {
                out.push_str(&String::from_utf8_lossy(e.as_ref()));
                out.push(' ');
            }
            Event::CData(e) if on => {
                out.push_str(&String::from_utf8_lossy(e.as_ref()));
                out.push(' ');
            }
            Event::End(e) if on && local_name(e.name().as_ref()) == wanted => {
                return Some(out.split_whitespace().collect::<Vec<_>>().join(" "))
            }
            Event::Eof => return Some(out.split_whitespace().collect::<Vec<_>>().join(" ")),
            _ => {}
        }
    }
}
fn hierarchy_indices(toc: &[TocItem]) -> HashMap<String, String> {
    let mut m = HashMap::new();
    for (i, x) in toc.iter().enumerate() {
        walk_indices(x, &(i + 1).to_string(), &mut m)
    }
    m
}
fn walk_indices(x: &TocItem, index: &str, m: &mut HashMap<String, String>) {
    if let Some(k) = x.href.split('#').next() {
        if !k.is_empty() {
            m.entry(k.into()).or_insert(index.into());
        }
    }
    for (i, c) in x.children.iter().enumerate() {
        walk_indices(c, &format!("{}.{}", index, i + 1), m)
    }
}
fn toc_levels(toc: &[TocItem]) -> HashMap<String, u32> {
    let mut m = HashMap::new();
    fn walk(x: &TocItem, m: &mut HashMap<String, u32>) {
        if let Some(k) = x.href.split('#').next() {
            if !k.is_empty() {
                let l = x.level;
                m.entry(k.into())
                    .and_modify(|v| *v = (*v).min(l))
                    .or_insert(l);
            }
        }
        for c in &x.children {
            walk(c, m)
        }
    }
    for x in toc {
        walk(x, &mut m)
    }
    m
}
fn first_heading(html: &str) -> Option<String> {
    let mut reader = Reader::from_str(html);
    let mut heading = false;
    let mut text = String::new();
    loop {
        match reader.read_event().ok()? {
            Event::Start(event) if is_heading(event.name().as_ref()) => heading = true,
            Event::Text(event) if heading => {
                text.push_str(&String::from_utf8_lossy(event.as_ref()))
            }
            Event::End(event) if heading && is_heading(event.name().as_ref()) => {
                let value = text.split_whitespace().collect::<Vec<_>>().join(" ");
                return (!value.is_empty()).then_some(value);
            }
            Event::Eof => return None,
            _ => {}
        }
    }
}

fn is_heading(name: &[u8]) -> bool {
    let name = local_name(name);
    name.len() == 2 && name[0].eq_ignore_ascii_case(&b'h') && (b'1'..=b'6').contains(&name[1])
}
fn html_to_text(html: &str) -> String {
    let mut reader = Reader::from_str(html);
    let mut skip_depth = 0usize;
    let mut out = String::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(event)) => {
                let name = event.name().as_ref().to_vec();
                let name = local_name(&name);
                if skip_depth > 0 {
                    skip_depth += 1;
                } else if matches!(name, b"head" | b"script" | b"style" | b"title") {
                    skip_depth = 1;
                } else if is_block_element(name) {
                    out.push(' ');
                }
            }
            Ok(Event::End(event)) => {
                let name = event.name().as_ref().to_vec();
                let name = local_name(&name);
                if skip_depth > 0 {
                    skip_depth -= 1;
                } else if is_block_element(name) {
                    out.push(' ');
                }
            }
            Ok(Event::Text(event)) if skip_depth == 0 => {
                out.push_str(&String::from_utf8_lossy(event.as_ref()));
                out.push(' ');
            }
            Ok(Event::CData(event)) if skip_depth == 0 => {
                out.push_str(&String::from_utf8_lossy(event.as_ref()));
                out.push(' ');
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn is_block_element(name: &[u8]) -> bool {
    matches!(
        name,
        b"address"
            | b"article"
            | b"aside"
            | b"blockquote"
            | b"br"
            | b"div"
            | b"dl"
            | b"dt"
            | b"dd"
            | b"figure"
            | b"footer"
            | b"h1"
            | b"h2"
            | b"h3"
            | b"h4"
            | b"h5"
            | b"h6"
            | b"header"
            | b"hr"
            | b"li"
            | b"main"
            | b"nav"
            | b"ol"
            | b"p"
            | b"pre"
            | b"section"
            | b"table"
            | b"td"
            | b"th"
            | b"tr"
            | b"ul"
    )
}

#[cfg(test)]
mod tests {
    use super::{first_heading, html_to_text, parse_epub};
    use std::io::{Cursor, Write};
    use zip::{write::SimpleFileOptions, ZipWriter};

    #[test]
    fn extracts_heading_and_text_without_language_specific_rules() {
        let html = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body><h2>Пролог</h2><p>Texto inicial.</p></body></html>"#;
        assert_eq!(first_heading(html).as_deref(), Some("Пролог"));
        assert_eq!(html_to_text(html), "Пролог Texto inicial.");
    }

    #[test]
    fn parses_prefixed_epub_namespaces_and_preserves_content() {
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = ZipWriter::new(&mut cursor);
            let options = SimpleFileOptions::default();
            zip.start_file("META-INF/container.xml", options).unwrap();
            zip.write_all(br#"<c:container xmlns:c="urn:oasis:names:tc:opendocument:xmlns:container"><c:rootfiles><c:rootfile full-path="OPS/package.opf"/></c:rootfiles></c:container>"#).unwrap();
            zip.start_file("OPS/package.opf", options).unwrap();
            zip.write_all(br#"<opf:package xmlns:opf="http://www.idpf.org/2007/opf"><opf:metadata><dc:title xmlns:dc="x">Livro</dc:title></opf:metadata><opf:manifest><opf:item id="chapter" href="chapter.xhtml" media-type="APPLICATION/XHTML+XML"/></opf:manifest><opf:spine><opf:itemref idref="chapter"/></opf:spine></opf:package>"#).unwrap();
            zip.start_file("OPS/chapter.xhtml", options).unwrap();
            zip.write_all(br#"<x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:body><x:h2>Chapter</x:h2><x:p>Readable content.</x:p></x:body></x:html>"#).unwrap();
            zip.finish().unwrap();
        }
        let book = parse_epub(Cursor::new(cursor.into_inner())).unwrap();
        assert_eq!(book.chapters.len(), 1);
        assert_eq!(book.chapters[0].text, "Chapter Readable content.");
    }
}

#[allow(dead_code)]
fn _dedupe_anchor_keys(items: &[TocItem]) -> HashSet<String> {
    items
        .iter()
        .flat_map(|x| {
            let mut v = vec![x.href.split('#').next().unwrap_or("").to_string()];
            v.extend(_dedupe_anchor_keys(&x.children));
            v
        })
        .collect()
}
