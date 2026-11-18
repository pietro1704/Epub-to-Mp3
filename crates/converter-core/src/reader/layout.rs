//! Whole-block pagination and safe highlight serialization share the text axis.
use super::{
    bounded,
    markup::{self, Document, Node},
    matches::{self, TextRange},
    ChapterRequest, ReaderAnchor, ReaderChapter, ReaderError, ReaderMatch, ReaderPage, Result,
    MAX_OUTPUT_BYTES,
};
use std::collections::{BTreeMap, HashSet};

pub(super) fn build(document: Document, request: &ChapterRequest) -> Result<ReaderChapter> {
    let preferences = &request.preferences;
    if !preferences.font_scale.is_finite()
        || !preferences.line_height.is_finite()
        || !preferences.width_rem.is_finite()
    {
        return Err(ReaderError::Invalid(
            "Reader typography must be finite".into(),
        ));
    }
    let budget = (2200.0 * preferences.width_rem.clamp(34.0, 68.0) / 48.0 * 1.05
        / preferences.font_scale.clamp(0.9, 1.4)
        * 1.75
        / preferences.line_height.clamp(1.45, 2.1))
    .round()
    .clamp(900.0, 4200.0) as usize;
    let (mut blocks, wrappers) = pagination_blocks(document.nodes);
    if !blocks.iter().any(has_content) {
        blocks.clear();
    }
    let mut text = String::new();
    markup::text(&blocks, &mut text);
    let search = matches::search(&text, &request.search_text)?;
    let audio = matches::audio(&text, &request.audio_text);
    let groups = group_blocks(blocks, budget);
    let mut pages = Vec::new();
    let mut anchors = Vec::new();
    let mut anchor_ids = HashSet::new();
    let mut offset = 0;
    let mut output_size = 0;
    for (page_index, mut nodes) in groups.into_iter().enumerate() {
        for (tag, attrs) in wrappers.iter().rev() {
            let mut attrs = attrs.clone();
            if page_index > 0 {
                attrs.remove("id");
                attrs.remove("name");
            }
            nodes = vec![Node::Element {
                tag: tag.clone(),
                attrs,
                children: nodes,
            }];
        }
        collect_anchors(&nodes, page_index, &mut anchors, &mut anchor_ids);
        let start = offset;
        let mut html = String::new();
        render_nodes(&nodes, &search, audio.as_ref(), &mut offset, &mut html)?;
        output_size += html.len();
        bounded(output_size, MAX_OUTPUT_BYTES, "page markup bytes")?;
        pages.push(ReaderPage {
            html,
            start,
            end: offset,
        });
    }
    let page_for = |range: &TextRange| {
        pages
            .iter()
            .position(|page| page.start <= range.start && page.end > range.start)
            .unwrap_or(0)
    };
    let search_matches = search
        .iter()
        .map(|range| ReaderMatch {
            start: range.start,
            end: range.end,
            page_index: page_for(range),
        })
        .collect();
    let audio_match = audio.as_ref().map(|range| ReaderMatch {
        start: range.start,
        end: range.end,
        page_index: page_for(range),
    });
    Ok(ReaderChapter {
        version: 1,
        offset_unit: "utf16",
        text,
        css: document.css,
        pages,
        search_matches,
        audio_match,
        anchors,
    })
}

type Wrapper = (String, BTreeMap<String, String>);

fn has_content(node: &Node) -> bool {
    match node {
        Node::Separator => false,
        Node::Text(value) => !value.trim().is_empty(),
        Node::Element { tag, children, .. } => {
            matches!(tag.as_str(), "img" | "hr") || children.iter().any(has_content)
        }
    }
}

fn pagination_blocks(mut nodes: Vec<Node>) -> (Vec<Node>, Vec<Wrapper>) {
    let mut wrappers = Vec::new();
    loop {
        // Source indentation between block elements is not a visible paragraph.
        let only_blocks = nodes.iter().all(|node| match node {
            Node::Separator => true,
            Node::Text(value) => value.trim().is_empty(),
            Node::Element { tag, .. } => matches!(
                tag.as_str(),
                "div"
                    | "section"
                    | "article"
                    | "p"
                    | "h1"
                    | "h2"
                    | "h3"
                    | "h4"
                    | "h5"
                    | "h6"
                    | "ul"
                    | "ol"
                    | "dl"
                    | "table"
                    | "pre"
                    | "blockquote"
                    | "figure"
                    | "hr"
            ),
        });
        if only_blocks {
            nodes.retain(|node| !matches!(node, Node::Text(value) if value.trim().is_empty()));
        }
        let unwrap = matches!(nodes.as_slice(), [Node::Element { tag, .. }]
            if matches!(tag.as_str(), "html" | "body" | "div" | "section" | "article"));
        if !unwrap {
            break;
        }
        if let Node::Element {
            tag,
            attrs,
            children,
        } = nodes.pop().expect("single wrapper")
        {
            wrappers.push((tag, attrs));
            nodes = children;
        }
    }
    (nodes, wrappers)
}

fn group_blocks(nodes: Vec<Node>, budget: usize) -> Vec<Vec<Node>> {
    let mut groups = Vec::new();
    let mut current = Vec::new();
    let mut characters = 0;
    for node in nodes {
        let count = text_len(&node);
        if !current.is_empty() && characters + count > budget {
            groups.push(std::mem::take(&mut current));
            characters = 0;
        }
        characters += count;
        current.push(node);
    }
    if !current.is_empty() {
        groups.push(current);
    }
    groups
}

fn text_len(node: &Node) -> usize {
    match node {
        Node::Separator => 1,
        Node::Text(value) => value.encode_utf16().count(),
        Node::Element { children, .. } => children.iter().map(text_len).sum(),
    }
}

fn collect_anchors(
    nodes: &[Node],
    page_index: usize,
    output: &mut Vec<ReaderAnchor>,
    seen: &mut HashSet<String>,
) {
    for node in nodes {
        if let Node::Element {
            attrs, children, ..
        } = node
        {
            for key in ["id", "name"] {
                if let Some(id) = attrs.get(key).filter(|value| !value.is_empty()) {
                    if seen.insert(id.clone()) {
                        output.push(ReaderAnchor {
                            id: id.clone(),
                            page_index,
                        });
                    }
                }
            }
            collect_anchors(children, page_index, output, seen);
        }
    }
}

fn render_nodes(
    nodes: &[Node],
    search: &[TextRange],
    audio: Option<&TextRange>,
    offset: &mut usize,
    html: &mut String,
) -> Result<()> {
    for node in nodes {
        match node {
            Node::Separator => *offset += 1,
            Node::Text(value) => render_text(value, search, audio, offset, html),
            Node::Element {
                tag,
                attrs,
                children,
            } => {
                let tag = if matches!(tag.as_str(), "html" | "body") {
                    "div"
                } else {
                    tag.as_str()
                };
                html.push('<');
                html.push_str(tag);
                for (key, value) in attrs {
                    html.push_str(&format!(" {key}=\"{}\"", markup::escape(value)));
                }
                html.push('>');
                if !matches!(tag, "br" | "hr" | "img") {
                    render_nodes(children, search, audio, offset, html)?;
                    html.push_str(&format!("</{tag}>"));
                }
            }
        }
        bounded(html.len(), MAX_OUTPUT_BYTES, "page markup bytes")?;
    }
    Ok(())
}

fn render_text(
    value: &str,
    search: &[TextRange],
    audio: Option<&TextRange>,
    offset: &mut usize,
    html: &mut String,
) {
    let start = *offset;
    let end = start + value.encode_utf16().count();
    let first = search.partition_point(|range| range.end <= start);
    let last = search.partition_point(|range| range.start < end);
    let local = &search[first..last];
    let mut boundaries = vec![start, end];
    for range in local
        .iter()
        .chain(audio.filter(|range| range.end > start && range.start < end))
    {
        boundaries.extend([range.start.max(start), range.end.min(end)]);
    }
    boundaries.sort_unstable();
    boundaries.dedup();
    let mut byte = 0;
    let mut unit = start;
    for pair in boundaries.windows(2) {
        let from = byte;
        while unit < pair[1] {
            let character = value[byte..]
                .chars()
                .next()
                .expect("UTF-16 range is on a character boundary");
            byte += character.len_utf8();
            unit += character.len_utf16();
        }
        let index = local.partition_point(|range| range.end <= pair[0]);
        let matched = local
            .get(index)
            .filter(|range| range.start <= pair[0] && range.end >= pair[1])
            .map(|_| first + index);
        let spoken = audio.is_some_and(|range| range.start <= pair[0] && range.end >= pair[1]);
        if matched.is_some() || spoken {
            html.push_str("<mark");
            if let Some(index) = matched {
                html.push_str(&format!(" data-reader-search=\"{index}\""));
            }
            if spoken {
                html.push_str(" data-reader-audio=\"true\"");
            }
            html.push('>');
        }
        html.push_str(&markup::escape(&value[from..byte]));
        if matched.is_some() || spoken {
            html.push_str("</mark>");
        }
    }
    *offset = end;
}
