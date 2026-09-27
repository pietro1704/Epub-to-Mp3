use quick_xml::events::Event;
use quick_xml::Reader;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TocItem {
    pub title: String,
    pub href: String,
    pub level: u32,
    pub children: Vec<TocItem>,
}

pub fn parse_ncx(xml: &str) -> Result<Vec<TocItem>, quick_xml::Error> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut roots: Vec<(TocItem, usize)> = Vec::new();
    let mut current: Vec<TocItem> = Vec::new();
    let mut title: Option<String> = None;
    let mut href: Option<String> = None;
    let mut depth = 0u32;
    loop {
        match reader.read_event()? {
            Event::Start(e) if e.name().as_ref() == b"navPoint" => {
                depth += 1;
                current.push(TocItem {
                    title: String::new(),
                    href: String::new(),
                    level: depth,
                    children: Vec::new(),
                });
            }
            Event::Start(e) if e.name().as_ref() == b"text" => {
                if let Event::Text(t) = reader.read_event()? {
                    title = Some(String::from_utf8_lossy(t.as_ref()).trim().into());
                }
            }
            Event::Empty(e) if e.name().as_ref() == b"content" => {
                href = e
                    .attributes()
                    .flatten()
                    .find(|a| a.key.as_ref() == b"src")
                    .and_then(|a| String::from_utf8(a.value.into_owned()).ok());
            }
            Event::End(e) if e.name().as_ref() == b"navPoint" => {
                let mut item = current.pop().unwrap();
                item.title = title.take().unwrap_or_default();
                item.href = href.take().unwrap_or_default();
                if let Some(parent) = current.last_mut() {
                    parent.children.push(item)
                } else {
                    roots.push((item, 0));
                }
                depth -= 1;
            }
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(roots.into_iter().map(|x| x.0).collect())
}

pub fn parse_nav(xml: &str) -> Result<Vec<TocItem>, quick_xml::Error> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut out = Vec::new();
    let mut stack: Vec<TocItem> = Vec::new();
    let mut in_toc = false;
    loop {
        match reader.read_event()? {
            Event::Start(e) if e.name().as_ref() == b"nav" => {
                in_toc = e.attributes().flatten().any(|a| {
                    a.key.as_ref() == b"type"
                        && String::from_utf8_lossy(&a.value)
                            .split_whitespace()
                            .any(|v| v.eq_ignore_ascii_case("toc"))
                });
            }
            Event::Start(e) if in_toc && e.name().as_ref() == b"li" => stack.push(TocItem {
                title: String::new(),
                href: String::new(),
                level: stack.len() as u32 + 1,
                children: Vec::new(),
            }),
            Event::Start(e) if in_toc && e.name().as_ref() == b"a" => {
                if let Some(item) = stack.last_mut() {
                    item.href = e
                        .attributes()
                        .flatten()
                        .find(|a| a.key.as_ref() == b"href")
                        .and_then(|a| String::from_utf8(a.value.into_owned()).ok())
                        .unwrap_or_default();
                    if let Event::Text(t) = reader.read_event()? {
                        item.title = String::from_utf8_lossy(t.as_ref()).trim().into();
                    }
                }
            }
            Event::End(e) if in_toc && e.name().as_ref() == b"li" => {
                if let Some(item) = stack.pop() {
                    if let Some(parent) = stack.last_mut() {
                        parent.children.push(item)
                    } else {
                        out.push(item)
                    }
                }
            }
            Event::End(e) if e.name().as_ref() == b"nav" => in_toc = false,
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(out)
}

pub fn minimum_levels(items: &[TocItem]) -> HashMap<String, u32> {
    let mut out = HashMap::new();
    fn walk(x: &TocItem, o: &mut HashMap<String, u32>) {
        let k = x.href.split('#').next().unwrap_or("");
        if !k.is_empty() {
            o.entry(k.to_string())
                .and_modify(|v| *v = (*v).min(x.level))
                .or_insert(x.level);
        }
        for c in &x.children {
            walk(c, o)
        }
    }
    for x in items {
        walk(x, &mut out)
    }
    out
}
