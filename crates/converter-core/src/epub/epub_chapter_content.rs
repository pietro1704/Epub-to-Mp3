//! Chapter heading/text projection and canonical TOC hierarchy mapping.
use super::epub_package::local_name;
use crate::toc::TocItem;
use quick_xml::events::Event;
use quick_xml::Reader;
use std::collections::{HashMap, HashSet};

fn flatten_toc(item: &TocItem) -> Vec<&TocItem> {
    let mut items = vec![item];
    for child in &item.children {
        items.extend(flatten_toc(child));
    }
    items
}

pub(super) fn toc_title_for(toc: &[TocItem], key: &str) -> Option<String> {
    toc.iter()
        .flat_map(flatten_toc)
        .find(|item| item.href.split('#').next().unwrap_or_default() == key)
        .map(|item| item.title.clone())
        .filter(|title| !title.is_empty())
}

pub(super) fn hierarchy_indices(toc: &[TocItem]) -> HashMap<String, String> {
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
pub(super) fn toc_levels(toc: &[TocItem]) -> HashMap<String, u32> {
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
pub(super) fn first_heading(html: &str) -> Option<String> {
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
pub(super) fn html_to_text(html: &str) -> String {
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
