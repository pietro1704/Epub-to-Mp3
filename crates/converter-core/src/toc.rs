use quick_xml::events::Event;
use quick_xml::Reader;

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
                // The label belongs to the innermost open navPoint, not to the next one closed.
                if let Event::Text(t) = reader.read_event()? {
                    if let Some(open) = current.last_mut() {
                        open.title = String::from_utf8_lossy(t.as_ref()).trim().into();
                    }
                }
            }
            Event::Empty(e) | Event::Start(e) if e.name().as_ref() == b"content" => {
                if let Some(open) = current.last_mut() {
                    open.href = e
                        .attributes()
                        .flatten()
                        .find(|a| a.key.as_ref() == b"src")
                        .and_then(|a| String::from_utf8(a.value.into_owned()).ok())
                        .unwrap_or_default();
                }
            }
            Event::End(e) if e.name().as_ref() == b"navPoint" => {
                let Some(item) = current.pop() else {
                    continue;
                };
                if let Some(parent) = current.last_mut() {
                    parent.children.push(item)
                } else {
                    roots.push((item, 0));
                }
                depth = depth.saturating_sub(1);
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
                    (a.key.as_ref() == b"type" || a.key.as_ref() == b"epub:type")
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

/// Fragments the TOC links into this chapter's file, percent-decoded.
pub(crate) fn toc_fragments(
    toc: &[TocItem],
    source_path: &str,
) -> std::collections::HashSet<String> {
    let mut found = std::collections::HashSet::new();
    for item in toc {
        if let Some((file, fragment)) = item.href.split_once('#') {
            let file = percent_encoding::percent_decode_str(file).decode_utf8_lossy();
            if !file.is_empty()
                && !fragment.is_empty()
                && (source_path == file || source_path.ends_with(&format!("/{file}")))
            {
                found.insert(
                    percent_encoding::percent_decode_str(fragment)
                        .decode_utf8_lossy()
                        .into_owned(),
                );
            }
        }
        found.extend(toc_fragments(&item.children, source_path));
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_epub_namespace_toc_attribute() {
        let items = parse_nav(
            r#"<html><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter</a></li></ol></nav></body></html>"#,
        )
        .unwrap();
        assert_eq!(items[0].href, "chapter.xhtml");
        assert_eq!(items[0].title, "Chapter");
    }

    fn point(id: &str, title: &str, href: Option<&str>, inner: &str) -> String {
        let content = href.map_or(String::new(), |h| format!(r#"<content src="{h}"/>"#));
        format!(
            r#"<navPoint id="{id}"><navLabel><text>{title}</text></navLabel>{content}{inner}</navPoint>"#
        )
    }

    #[test]
    fn ncx_parents_keep_their_own_title_href_and_level_at_depth_three() {
        let deep = point("c", "Section", Some("s.xhtml#a"), "");
        let chapter = point("b", "Chapter", Some("c1.xhtml"), &deep);
        let part = point("a", "Part One", Some("p1.xhtml"), &chapter);
        let hrefless = point(
            "d",
            "Part Two",
            None,
            &point("e", "Chapter Two", Some("c2.xhtml"), ""),
        );
        let xml = format!(
            r#"<ncx><docTitle><text>Book</text></docTitle><navMap>{part}{hrefless}</navMap></ncx>"#
        );
        let toc = parse_ncx(&xml).unwrap();
        assert_eq!(toc.len(), 2);
        assert_eq!(
            (toc[0].title.as_str(), toc[0].href.as_str(), toc[0].level),
            ("Part One", "p1.xhtml", 1)
        );
        let chapter = &toc[0].children[0];
        assert_eq!(
            (chapter.title.as_str(), chapter.href.as_str(), chapter.level),
            ("Chapter", "c1.xhtml", 2)
        );
        let section = &chapter.children[0];
        assert_eq!(
            (section.title.as_str(), section.href.as_str(), section.level),
            ("Section", "s.xhtml#a", 3)
        );
        assert_eq!(
            (toc[1].title.as_str(), toc[1].href.as_str()),
            ("Part Two", "")
        );
        assert_eq!(toc[1].children[0].href, "c2.xhtml");
    }
}
