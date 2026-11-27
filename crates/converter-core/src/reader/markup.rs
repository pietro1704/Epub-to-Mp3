//! HTML5 parsing into a small owned tree, followed by explicit safe serialization.
use super::{bounded, css, ReaderError, Result, MAX_CHAPTER_BYTES, MAX_DEPTH, MAX_NODES};
use scraper::{ElementRef, Html, Node as HtmlNode};
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub(super) enum Node {
    Text(String),
    // A structural newline on the text axis, with no extra rendered whitespace.
    Separator,
    Element {
        tag: String,
        attrs: BTreeMap<String, String>,
        children: Vec<Node>,
    },
}

pub(super) struct Document {
    pub nodes: Vec<Node>,
    pub css: String,
}

pub(super) fn parse(source: &str) -> Result<Vec<Node>> {
    bounded(source.len(), MAX_CHAPTER_BYTES, "chapter markup bytes")?;
    // Bound likely allocation before HTML5 tree construction as well as after it.
    bounded(
        source.bytes().filter(|byte| *byte == b'<').count(),
        MAX_NODES / 2,
        "markup tokens",
    )?;
    let parsed = Html::parse_document(source);
    let mut count = 0;
    let root = parsed.root_element();
    let body = root
        .children()
        .filter_map(ElementRef::wrap)
        .find(|node| node.value().name() == "body")
        .ok_or_else(|| ReaderError::Invalid("HTML5 document has no body".into()))?;
    let mut nodes = children(body, 0, &mut count)?;
    // Retain inherited language/direction and body typography without emitting
    // document-level elements into the client's shadow root.
    for element in [body, root] {
        let attrs: BTreeMap<String, String> = element
            .value()
            .attrs()
            .filter(|(key, _)| {
                matches!(*key, "lang" | "xml:lang" | "dir" | "class" | "id" | "style")
            })
            .map(|(key, value)| (key.to_owned(), value.to_owned()))
            .collect();
        nodes = vec![Node::Element {
            tag: element.value().name().into(),
            attrs,
            children: nodes,
        }];
    }
    Ok(nodes)
}

fn children(element: ElementRef<'_>, depth: usize, count: &mut usize) -> Result<Vec<Node>> {
    bounded(depth, MAX_DEPTH, "markup depth")?;
    let mut nodes = Vec::new();
    for child in element.children() {
        *count += 1;
        bounded(*count, MAX_NODES, "markup nodes")?;
        match child.value() {
            HtmlNode::Text(text) => nodes.push(Node::Text(text.to_string())),
            HtmlNode::Element(value) => {
                let tag = value.name().to_ascii_lowercase();
                // Drop foreign-content subtrees, even if browser repair gave a
                // descendant the same spelling as an allowed HTML tag.
                if value.name.ns.as_ref() != "http://www.w3.org/1999/xhtml" || remove_entirely(&tag)
                {
                    continue;
                }
                let child = ElementRef::wrap(child).expect("element node");
                let descendants = children(child, depth + 1, count)?;
                if allowed(&tag) {
                    let attrs = value
                        .attrs()
                        .map(|(key, value)| (key.to_ascii_lowercase(), value.to_owned()))
                        .collect();
                    nodes.push(Node::Element {
                        tag,
                        attrs,
                        children: descendants,
                    });
                } else {
                    nodes.extend(descendants);
                }
            }
            _ => {}
        }
    }
    Ok(nodes)
}

pub(super) fn sanitize(source: &str, stylesheet: &str) -> Result<Document> {
    let mut nodes = parse(source)?;
    let mut css = css::stylesheet(stylesheet)?;
    let mut sequence = 0;
    clean(&mut nodes, &mut css, &mut sequence)?;
    nodes = super::text_axis::normalize(nodes);
    Ok(Document { nodes, css })
}

pub(super) fn clean(
    nodes: &mut Vec<Node>,
    stylesheet: &mut String,
    sequence: &mut usize,
) -> Result<()> {
    for node in nodes.iter_mut() {
        let Node::Element {
            tag,
            attrs,
            children,
        } = node
        else {
            continue;
        };
        let original = std::mem::take(attrs);
        for (key, value) in original.iter() {
            if value.len() > MAX_CHAPTER_BYTES {
                continue;
            }
            let allowed = match key.as_str() {
                "id" | "title" | "lang" => {
                    value.len() <= 2048 && !value.chars().any(char::is_control)
                }
                "class" => false,
                "dir" => matches!(value.as_str(), "ltr" | "rtl" | "auto"),
                "colspan" | "rowspan" if matches!(tag.as_str(), "td" | "th") => {
                    value.parse::<usize>().is_ok_and(|n| (1..=100).contains(&n))
                }
                "start" if tag == "ol" => value.parse::<i32>().is_ok(),
                "alt" if tag == "img" => value.len() <= 4096,
                "name" if tag == "a" => value.len() <= 2048 && !value.chars().any(char::is_control),
                _ => false,
            };
            if allowed {
                attrs.insert(key.clone(), value.clone());
            }
        }
        if !attrs.contains_key("lang") {
            if let Some(language) = original
                .get("xml:lang")
                .filter(|value| value.len() <= 2048 && !value.chars().any(char::is_control))
            {
                attrs.insert("lang".into(), language.clone());
            }
        }
        if let Some(classes) = original.get("class").filter(|value| value.len() <= 2048) {
            let classes = classes
                .split_whitespace()
                .filter(|value| !value.starts_with("reader-root-"))
                .collect::<Vec<_>>()
                .join(" ");
            if !classes.is_empty() {
                attrs.insert("class".into(), classes);
            }
        }
        if matches!(tag.as_str(), "html" | "body") {
            let class = format!("reader-root-{tag}");
            attrs
                .entry("class".into())
                .and_modify(|value| {
                    value.push(' ');
                    value.push_str(&class);
                })
                .or_insert(class);
        }
        if let Some(style) = original.get("style") {
            let declarations = css::inline(style);
            if !declarations.is_empty() {
                let class = format!("reader-inline-{sequence}");
                *sequence += 1;
                attrs
                    .entry("class".into())
                    .and_modify(|value| {
                        value.push(' ');
                        value.push_str(&class);
                    })
                    .or_insert(class.clone());
                stylesheet.push_str(&format!(".{class} {{ {declarations} }}\n"));
                bounded(
                    stylesheet.len(),
                    super::MAX_CSS_BYTES,
                    "sanitized CSS bytes",
                )?;
            }
        }
        if tag == "a" {
            if let Some(href) = original.get("href").and_then(|value| safe_external(value)) {
                attrs.insert("href".into(), href);
                attrs.insert("target".into(), "_blank".into());
                attrs.insert("rel".into(), "noopener noreferrer".into());
            }
            if let Some(index) = original
                .get("data-reader-chapter")
                .filter(|value| valid_index(value))
            {
                attrs.remove("href");
                attrs.insert("data-reader-chapter".into(), index.clone());
                if let Some(fragment) = original
                    .get("data-reader-fragment")
                    .filter(|v| v.len() <= 2048 && !v.chars().any(char::is_control))
                {
                    attrs.insert("data-reader-fragment".into(), fragment.clone());
                }
                // Makes the inert route keyboard-operable; click is intercepted.
                attrs.insert("href".into(), "#".into());
            }
        }
        if tag == "img" {
            if let Some(src) = original
                .get("src")
                .filter(|value| super::resources::safe_data_image(value))
            {
                attrs.insert("src".into(), src.clone());
            } else {
                *node = Node::Text(original.get("alt").cloned().unwrap_or_default());
                continue;
            }
        }
        clean(children, stylesheet, sequence)?;
    }
    Ok(())
}

pub(super) fn valid_index(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .split('.')
            .all(|part| !part.is_empty() && part.bytes().all(|c| c.is_ascii_digit()))
}

pub(super) fn safe_external(value: &str) -> Option<String> {
    let value = value.trim();
    if value.len() > 4096
        || value
            .chars()
            .any(|c| c.is_control() || matches!(c, '\\' | '<' | '>'))
    {
        return None;
    }
    let lower = value.to_ascii_lowercase();
    let external = ["https://", "http://"].iter().any(|prefix| {
        lower.strip_prefix(prefix).is_some_and(|authority| {
            !authority.is_empty()
                && !authority.starts_with('/')
                && !authority.chars().any(char::is_whitespace)
        })
    }) || lower
        .strip_prefix("mailto:")
        .is_some_and(|address| !address.is_empty() && !address.chars().any(char::is_whitespace));
    external.then(|| value.to_owned())
}

pub(super) fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

pub(super) fn fallback(text: &str, stylesheet: &str) -> Result<Document> {
    // Build text nodes directly: escaping an otherwise bounded input must not
    // inflate it into an oversized HTML input before it reaches serialization.
    bounded(
        text.bytes().filter(|byte| *byte == b'\n').count(),
        MAX_NODES / 3,
        "fallback lines",
    )?;
    let mut nodes = Vec::new();
    for paragraph in text.split("\n\n") {
        let mut children = Vec::new();
        for (index, line) in paragraph.split('\n').enumerate() {
            if index > 0 {
                children.push(Node::Element {
                    tag: "br".into(),
                    attrs: BTreeMap::new(),
                    children: Vec::new(),
                });
            }
            children.push(Node::Text(line.into()));
        }
        nodes.push(Node::Element {
            tag: "p".into(),
            attrs: BTreeMap::new(),
            children,
        });
    }
    for tag in ["body", "html"] {
        nodes = vec![Node::Element {
            tag: tag.into(),
            attrs: BTreeMap::from([("class".into(), format!("reader-root-{tag}"))]),
            children: nodes,
        }];
    }
    Ok(Document {
        nodes: super::text_axis::normalize(nodes),
        css: css::stylesheet(stylesheet)?,
    })
}

pub(super) fn serialize(nodes: &[Node]) -> String {
    let mut html = String::new();
    for node in nodes {
        match node {
            Node::Separator => {}
            Node::Text(text) => html.push_str(&escape(text)),
            Node::Element {
                tag,
                attrs,
                children,
            } => {
                html.push('<');
                html.push_str(tag);
                for (key, value) in attrs {
                    html.push_str(&format!(" {key}=\"{}\"", escape(value)));
                }
                html.push('>');
                if !matches!(tag.as_str(), "br" | "hr" | "img") {
                    html.push_str(&serialize(children));
                    html.push_str(&format!("</{tag}>"));
                }
            }
        }
    }
    html
}

pub(super) fn text(nodes: &[Node], output: &mut String) {
    for node in nodes {
        match node {
            Node::Separator => output.push('\n'),
            Node::Text(value) => output.push_str(value),
            Node::Element { children, .. } => text(children, output),
        }
    }
}

/// Scalar offset on the `text` axis where each wanted `id` element starts (first one wins).
pub(super) fn anchors(
    nodes: &[Node],
    wanted: &std::collections::HashSet<String>,
) -> Vec<(String, usize)> {
    fn walk(
        nodes: &[Node],
        wanted: &std::collections::HashSet<String>,
        offset: &mut usize,
        out: &mut Vec<(String, usize)>,
    ) {
        for node in nodes {
            match node {
                Node::Separator => *offset += 1,
                Node::Text(value) => *offset += value.chars().count(),
                Node::Element {
                    attrs, children, ..
                } => {
                    if let Some(id) = attrs.get("id").filter(|id| wanted.contains(*id)) {
                        if !out.iter().any(|(seen, _)| seen == id) {
                            out.push((id.clone(), *offset));
                        }
                    }
                    walk(children, wanted, offset, out);
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(nodes, wanted, &mut 0, &mut out);
    out
}

fn remove_entirely(tag: &str) -> bool {
    matches!(
        tag,
        "script"
            | "style"
            | "head"
            | "iframe"
            | "object"
            | "embed"
            | "form"
            | "input"
            | "button"
            | "textarea"
            | "select"
            | "video"
            | "audio"
            | "source"
            | "link"
            | "meta"
            | "template"
            | "noscript"
            | "svg"
            | "math"
            | "canvas"
    )
}

fn allowed(tag: &str) -> bool {
    matches!(
        tag,
        "a" | "abbr"
            | "article"
            | "b"
            | "blockquote"
            | "br"
            | "caption"
            | "cite"
            | "code"
            | "dd"
            | "div"
            | "dl"
            | "dt"
            | "em"
            | "figcaption"
            | "figure"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "hr"
            | "i"
            | "img"
            | "li"
            | "mark"
            | "ol"
            | "p"
            | "pre"
            | "q"
            | "s"
            | "section"
            | "small"
            | "span"
            | "strong"
            | "sub"
            | "sup"
            | "table"
            | "tbody"
            | "td"
            | "tfoot"
            | "th"
            | "thead"
            | "tr"
            | "u"
            | "ul"
    )
}
