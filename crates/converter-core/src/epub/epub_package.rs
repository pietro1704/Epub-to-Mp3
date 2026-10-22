//! EPUB manifest/spine metadata and normalized resource references.
use super::EpubError;
use percent_encoding::percent_decode_str;
use quick_xml::events::Event;
use quick_xml::Reader;
use std::collections::HashMap;
use std::path::Path;

pub(super) type Manifest = HashMap<String, (String, Option<String>)>;
pub(super) type PackageParts = (Manifest, Vec<String>, Option<String>, Option<String>);

pub(super) fn parse_package(xml: &str, _path: &str) -> Result<PackageParts, EpubError> {
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

pub(super) fn resolve_resource_path(base: &Path, href: &str) -> String {
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

pub(super) fn local_name(name: &[u8]) -> &[u8] {
    name.rsplit(|byte| *byte == b':').next().unwrap_or(name)
}

pub(super) fn normalized_media_type(value: Option<&str>) -> Option<String> {
    value
        .and_then(|raw| raw.split(';').next())
        .map(|raw| raw.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
}

pub(super) fn xml_attr(xml: &str, element: &[u8], key: &[u8]) -> Option<String> {
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
pub(super) fn xml_text(xml: &str, wanted: &[u8]) -> Option<String> {
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
