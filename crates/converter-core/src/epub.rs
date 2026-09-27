use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};

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
    let toc = if let Some(href) = ncx_href {
        parse_ncx(&read_entry(&mut archive, &join(opf_dir, &href))?).unwrap_or_default()
    } else if let Some(href) = nav_href {
        parse_nav(&read_entry(&mut archive, &join(opf_dir, &href))?).unwrap_or_default()
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
        let path = join(opf_dir, &href);
        let html = read_entry(&mut archive, &path)?;
        let text = html_to_text(&html);
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

fn parse_package(
    xml: &str,
    _path: &str,
) -> Result<
    (
        HashMap<String, (String, Option<String>)>,
        Vec<String>,
        Option<String>,
        Option<String>,
    ),
    EpubError,
> {
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
            Ok(Event::Start(e)) if e.name().as_ref() == b"manifest" => in_manifest = true,
            Ok(Event::End(e)) if e.name().as_ref() == b"manifest" => in_manifest = false,
            Ok(Event::Start(e)) if e.name().as_ref() == b"spine" => {
                in_spine = true;
                if let Some(v) = attr(&e, b"toc") {
                    ncx = Some(v);
                }
            }
            Ok(Event::End(e)) if e.name().as_ref() == b"spine" => in_spine = false,
            Ok(Event::Empty(e)) | Ok(Event::Start(e))
                if e.name().as_ref() == b"item" && in_manifest =>
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
                    if attr(&e, b"media-type").as_deref() == Some("application/x-dtbncx+xml") {
                        ncx = Some(href.clone());
                    }
                    manifest.insert(id, (href, attr(&e, b"media-type")));
                }
            }
            Ok(Event::Empty(e)) if e.name().as_ref() == b"itemref" && in_spine => {
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
fn join(base: &Path, href: &str) -> String {
    let mut p = PathBuf::from(base);
    p.push(href.split('#').next().unwrap_or(href));
    p.to_string_lossy().replace('\\', "/")
}
fn attr(e: &quick_xml::events::BytesStart<'_>, key: &[u8]) -> Option<String> {
    e.attributes()
        .flatten()
        .find(|a| a.key.as_ref() == key)
        .and_then(|a| String::from_utf8(a.value.into_owned()).ok())
}
fn xml_attr(xml: &str, element: &[u8], key: &[u8]) -> Option<String> {
    let mut r = Reader::from_str(xml);
    loop {
        match r.read_event().ok()? {
            Event::Empty(e) | Event::Start(e) if e.name().as_ref() == element => {
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
    let mut out = None;
    loop {
        match r.read_event().ok()? {
            Event::Start(e) if e.name().as_ref() == wanted => on = true,
            Event::Text(e) if on => out = Some(String::from_utf8_lossy(e.as_ref()).into_owned()),
            Event::End(e) if e.name().as_ref() == wanted => return out,
            Event::Eof => return out,
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
    let lower = html.to_ascii_lowercase();
    let start = lower.find("<h1")?;
    let gt = lower[start..].find('>')? + start;
    let end = lower[gt..].find("</h1>")? + gt;
    Some(html[gt + 1..end].trim().into())
}
fn html_to_text(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut tag = false;
    for c in html.chars() {
        if c == '<' {
            tag = true;
            out.push('\n')
        } else if c == '>' {
            tag = false
        } else if !tag {
            out.push(c)
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
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
