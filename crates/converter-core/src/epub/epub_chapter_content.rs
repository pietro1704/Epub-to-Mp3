//! Chapter heading/text projection and canonical TOC hierarchy mapping.
use super::epub_package::local_name;
use crate::toc::TocItem;
use quick_xml::events::Event;
use quick_xml::Reader;
use std::collections::HashMap;

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
            Event::CData(event) if heading => {
                text.push_str(&String::from_utf8_lossy(event.as_ref()))
            }
            Event::GeneralRef(event) if heading => push_reference(&mut text, &event),
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
/// Append the character an XML reference stands for: the five predefined entities,
/// numeric references and `&nbsp;`. Any other name becomes a space so the words
/// around it are never joined.
fn push_reference(out: &mut String, reference: &quick_xml::events::BytesRef<'_>) {
    if let Ok(Some(character)) = reference.resolve_char_ref() {
        out.push(character);
        return;
    }
    let name = String::from_utf8_lossy(reference.as_ref());
    out.push_str(quick_xml::escape::resolve_predefined_entity(&name).unwrap_or(" "));
}

/// Elements that separate words without ending a paragraph.
fn is_word_separator(name: &[u8]) -> bool {
    matches!(
        name,
        b"body" | b"caption" | b"figcaption" | b"img" | b"option"
    )
}

/// Raw (unnormalized) projection plus the marks the note positions are derived from.
struct RawProjection {
    out: String,
    paragraph_boundaries: Vec<usize>,
    heading_boundaries: Vec<usize>,
    /// (raw start of the link, raw end of the link, fragment) for note-like links.
    ref_marks: Vec<(usize, usize, String, bool)>,
    /// Raw (start, end) of every element that carries an `id`.
    id_ranges: HashMap<String, (usize, usize)>,
}

fn attribute(event: &quick_xml::events::BytesStart<'_>, wanted: &[u8]) -> Option<String> {
    event
        .attributes()
        .with_checks(false)
        .flatten()
        .find(|attribute| local_name(attribute.key.as_ref()) == wanted)
        .map(|attribute| String::from_utf8_lossy(&attribute.value).into_owned())
}

/// A same-document link is a note reference when it targets a fragment whose name or
/// `epub:type` says note (mirrors `epub_footnotes`, which resolves the same links).
fn note_fragment(event: &quick_xml::events::BytesStart<'_>) -> Option<(String, bool)> {
    let href = attribute(event, b"href")?;
    let (path, fragment) = href.trim().split_once('#')?;
    if fragment.is_empty() {
        return None;
    }
    let fragment = percent_encoding::percent_decode_str(fragment)
        .decode_utf8_lossy()
        .into_owned();
    super::epub_footnotes::is_note_link(
        &href,
        attribute(event, b"type").as_deref(),
        attribute(event, b"role").as_deref(),
    )
    .then(|| (fragment, path.is_empty()))
}

fn project_raw(html: &str) -> RawProjection {
    let ordered = crate::parallel_columns::reading_order(html);
    let mut reader = Reader::from_str(&ordered);
    let mut skip_depth = 0usize;
    let mut out = String::new();
    let mut paragraph_boundaries = Vec::new();
    let mut heading_boundaries = Vec::new();
    let mut heading_start = None;
    let mut ref_marks = Vec::new();
    let mut id_ranges = HashMap::new();
    // Open elements outside skipped subtrees: (id, raw start) and the open link, if any.
    let mut open: Vec<Option<(String, usize)>> = Vec::new();
    let mut open_ref: Option<(usize, (String, bool), usize)> = None;
    loop {
        match reader.read_event() {
            Ok(Event::Start(event)) => {
                let name = event.name().as_ref().to_vec();
                let name = local_name(&name);
                if skip_depth > 0 {
                    skip_depth += 1;
                } else if matches!(name, b"head" | b"script" | b"style" | b"title") {
                    skip_depth = 1;
                } else {
                    let start = out.len();
                    open.push(attribute(&event, b"id").map(|id| (id, start)));
                    if name == b"a" && open_ref.is_none() {
                        if let Some(fragment) = note_fragment(&event) {
                            open_ref = Some((start, fragment, open.len()));
                        }
                    }
                    if is_word_separator(name) {
                        out.push(' ');
                    }
                    if is_block_element(name) || is_heading(name) {
                        paragraph_boundaries.push(out.len());
                        out.push(' ');
                        if is_heading(name) {
                            heading_start = Some(out.len());
                        }
                    }
                }
            }
            Ok(Event::End(event)) => {
                let name = event.name().as_ref().to_vec();
                let name = local_name(&name);
                if skip_depth > 0 {
                    skip_depth -= 1;
                } else {
                    if let Some(Some((id, start))) = open.pop() {
                        id_ranges.entry(id).or_insert((start, out.len()));
                    }
                    if open_ref
                        .as_ref()
                        .is_some_and(|(_, _, depth)| *depth == open.len() + 1)
                    {
                        let (start, (fragment, same_document), _) =
                            open_ref.take().expect("open note reference");
                        ref_marks.push((start, out.len(), fragment, same_document));
                    }
                    if is_block_element(name) || is_heading(name) {
                        if is_heading(name) {
                            if heading_start
                                .take()
                                .is_some_and(|start| !out[start..].trim().is_empty())
                            {
                                heading_boundaries.push(out.len());
                            }
                        }
                        paragraph_boundaries.push(out.len());
                        out.push(' ');
                    }
                    if is_word_separator(name) {
                        out.push(' ');
                    }
                }
            }
            Ok(Event::Empty(event)) if skip_depth == 0 => {
                let name = event.name();
                let name = local_name(name.as_ref());
                if is_block_element(name) {
                    paragraph_boundaries.push(out.len());
                    out.push(' ');
                } else if is_word_separator(name) {
                    out.push(' ');
                }
            }
            Ok(Event::Text(event)) if skip_depth == 0 => {
                out.push_str(&String::from_utf8_lossy(event.as_ref()));
            }
            Ok(Event::CData(event)) if skip_depth == 0 => {
                out.push_str(&String::from_utf8_lossy(event.as_ref()));
            }
            Ok(Event::GeneralRef(event)) if skip_depth == 0 => push_reference(&mut out, &event),
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    RawProjection {
        out,
        paragraph_boundaries,
        heading_boundaries,
        ref_marks,
        id_ranges,
    }
}

pub(super) fn html_to_text_projection(html: &str) -> (String, Vec<usize>, Vec<usize>) {
    let raw = project_raw(html);
    normalize_with_paragraph_ends(&raw.out, &raw.paragraph_boundaries, &raw.heading_boundaries)
}

/// A footnote reference found in the chapter text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteRef {
    /// Scalar offset right after the reference label on the normalized text axis.
    pub end: usize,
    /// Fragment id the reference links to.
    pub target: String,
    /// Scalar range of the note body when it lives inside this same document.
    pub body: Option<std::ops::Range<usize>>,
}

/// Where note references and same-document note bodies sit on the normalized text axis
/// returned by `html_to_text_projection` (the axis itself is unchanged).
pub(super) fn note_positions(html: &str) -> Vec<NoteRef> {
    let raw = project_raw(html);
    if raw.ref_marks.is_empty() {
        return Vec::new();
    }
    // Token table: (raw start, scalar start, raw end) of the normalized words.
    let mut tokens = Vec::new();
    let mut cursor = 0;
    let mut scalars = 0;
    for token in raw.out.split_whitespace() {
        let start = cursor + raw.out[cursor..].find(token).expect("source token");
        if scalars > 0 {
            scalars += 1;
        }
        let width = token.chars().count();
        tokens.push((start, scalars, start + token.len()));
        scalars += width;
        cursor = start + token.len();
    }
    let first_at_or_after = |mark: usize| {
        tokens
            .iter()
            .find(|token| token.0 >= mark)
            .map_or(scalars, |token| token.1)
    };
    let last_before = |mark: usize| {
        tokens
            .iter()
            .rev()
            .find(|token| token.0 < mark)
            .map_or(0, |token| {
                token.1
                    + raw.out[token.0..mark.min(token.2)]
                        .trim_end()
                        .chars()
                        .count()
            })
    };
    let mut refs = Vec::new();
    for (_, end, fragment, same_document) in &raw.ref_marks {
        let end_scalar = last_before(*end);
        if end_scalar == 0 {
            continue;
        }
        let body = same_document
            .then(|| raw.id_ranges.get(fragment))
            .flatten()
            .map(|(body_start, body_end)| first_at_or_after(*body_start)..last_before(*body_end))
            .filter(|range| range.start < range.end);
        refs.push(NoteRef {
            end: end_scalar,
            target: fragment.clone(),
            body,
        });
    }
    refs
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

/// Project block ends onto the existing normalized Unicode-scalar text axis.
fn normalize_with_paragraph_ends(
    raw: &str,
    boundaries: &[usize],
    headings: &[usize],
) -> (String, Vec<usize>, Vec<usize>) {
    let mut normalized = String::new();
    let mut paragraph_ends = Vec::new();
    let mut heading_ends = Vec::new();
    let mut heading = 0;
    let mut boundary = 0;
    let mut raw_cursor = 0;
    let mut scalars = 0;
    for token in raw.split_whitespace() {
        let start = raw_cursor + raw[raw_cursor..].find(token).expect("source token");
        while heading < headings.len() && headings[heading] <= start {
            if scalars > 0 && heading_ends.last() != Some(&scalars) {
                heading_ends.push(scalars);
            }
            heading += 1;
        }
        while boundary < boundaries.len() && boundaries[boundary] <= start {
            if scalars > 0 && paragraph_ends.last() != Some(&scalars) {
                paragraph_ends.push(scalars);
            }
            boundary += 1;
        }
        if !normalized.is_empty() {
            normalized.push(' ');
            scalars += 1;
        }
        normalized.push_str(token);
        scalars += token.chars().count();
        raw_cursor = start + token.len();
    }
    if !boundaries.is_empty() && scalars > 0 && paragraph_ends.last() != Some(&scalars) {
        paragraph_ends.push(scalars);
    }
    if heading < headings.len() && scalars > 0 && heading_ends.last() != Some(&scalars) {
        heading_ends.push(scalars);
    }
    (normalized, paragraph_ends, heading_ends)
}

#[cfg(test)]
mod paragraph_tests {
    use super::*;

    #[test]
    fn paragraph_metadata_preserves_canonical_text_and_unicode_axis() {
        let html = "<html><head><title>Ignore</title><style>hidden</style></head><body><h1>Título</h1><p>Água <em>clara</em> e fresca.</p><p>Segunda frase.</p><script>hidden</script></body></html>";
        let (text, ends, _) = html_to_text_projection(html);
        assert_eq!(text, "Título Água clara e fresca. Segunda frase.");
        assert_eq!(ends, vec![6, 27, 42]);
        assert!(ends.iter().all(|end| *end <= text.chars().count()));
    }

    #[test]
    fn nested_empty_blocks_inline_markup_and_missing_metadata_are_compatible() {
        for (html, expected) in [
            (
                "<div><p>One <b>bold</b> word.</p><p></p><p>Next.</p></div>",
                "One bold word. Next.",
            ),
            ("plain   text", "plain text"),
            ("<p>   </p>", ""),
            ("<ul><li>First</li><li>Second</li></ul>", "First Second"),
        ] {
            let (text, ends, _) = html_to_text_projection(html);
            assert_eq!(text, expected);
            assert!(ends.windows(2).all(|pair| pair[0] < pair[1]));
            assert!(ends
                .iter()
                .all(|end| *end > 0 && *end <= text.chars().count()));
        }
        assert!(html_to_text_projection("plain text").1.is_empty());
    }
}

#[cfg(test)]
mod heading_tests {
    use super::*;

    #[test]
    fn headings_preserve_plain_text_and_only_mark_structural_titles() {
        let (text, _, ends) = html_to_text_projection("<head><title>Hidden</title></head><x:H1>Água <em>clara</em></x:H1><p>A body title is ordinary prose.</p><h2>Fim</h2><p>Final.</p>");
        assert_eq!(
            text,
            "Água clara A body title is ordinary prose. Fim Final."
        );
        assert_eq!(
            ends,
            [
                "Água clara".chars().count(),
                "Água clara A body title is ordinary prose. Fim"
                    .chars()
                    .count()
            ]
        );
    }

    #[test]
    fn final_heading_is_marked_without_marking_a_later_body_end() {
        assert_eq!(html_to_text_projection("<h1>Title</h1><p>Body</p>").2, [5]);
        assert_eq!(html_to_text_projection("<p>Body</p><h6>Title</h6>").2, [10]);
        assert!(html_to_text_projection("<p>Only body</p><h1> </h1>")
            .2
            .is_empty());
    }
}

#[cfg(test)]
mod note_position_tests {
    use super::*;

    #[test]
    fn note_references_and_same_document_bodies_are_positioned_on_the_text_axis() {
        let html = "<p>Texto antes<a href=\"#n1\" epub:type=\"noteref\">1</a> e depois.</p><aside id=\"n1\" epub:type=\"footnote\"><p>Corpo da nota.</p></aside>";
        let (text, _, _) = html_to_text_projection(html);
        assert_eq!(text, "Texto antes1 e depois. Corpo da nota.");
        let notes = note_positions(html);
        let after_label = "Texto antes1".chars().count();
        let body_start = "Texto antes1 e depois. ".chars().count();
        assert_eq!(
            notes,
            vec![NoteRef {
                end: after_label,
                target: "n1".into(),
                body: Some(body_start..text.chars().count()),
            }]
        );
    }

    #[test]
    fn a_reference_to_another_document_has_no_body_in_this_chapter() {
        let notes = note_positions(
            "<p>Texto<a href=\"notes.xhtml#n1\">1</a>.</p><p id=\"n1\">Mesmo id.</p>",
        );
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].target, "n1");
        assert_eq!(notes[0].body, None);
    }

    #[test]
    fn ordinary_links_are_not_notes() {
        let notes = note_positions(
            "<p>Veja <a href=\"cap2.xhtml\">aqui</a> e <a href=\"#topo\">topo</a>.</p>",
        );
        assert!(notes.is_empty());
    }
}

#[cfg(test)]
mod text_node_tests {
    use super::*;

    #[test]
    fn predefined_and_numeric_references_are_resolved() {
        let html = "<h1>Tom &amp; Jerry</h1><p>if (a &lt; b &amp;&amp; b &gt; c) &quot;ok&quot; d&apos;&#193;gua &#x2014; fim&nbsp;aqui</p>";
        assert_eq!(
            html_to_text_projection(html).0,
            "Tom & Jerry if (a < b && b > c) \"ok\" d'Água — fim aqui"
        );
        assert_eq!(first_heading(html).as_deref(), Some("Tom & Jerry"));
    }

    #[test]
    fn an_unknown_named_reference_never_joins_words() {
        assert_eq!(html_to_text_projection("<p>um&bogus;dois</p>").0, "um dois");
    }

    #[test]
    fn inline_markup_never_splits_words() {
        let html = "<p><span class=\"dropcap\">N</span>ADA do <em>Fluminense</em>, nem<!-- c --> isso.</p>";
        assert_eq!(
            html_to_text_projection(html).0,
            "NADA do Fluminense, nem isso."
        );
    }

    #[test]
    fn block_and_break_boundaries_still_separate_words() {
        let html = "<body><div>um</div><p>dois<br/>três<br />quatro<hr/>cinco</p><table><caption>seis</caption><tr><td>sete</td><td>oito</td></tr></table><figure><img src=\"a\"/><figcaption>nove</figcaption>dez</figure></body>";
        assert_eq!(
            html_to_text_projection(html).0,
            "um dois três quatro cinco seis sete oito nove dez"
        );
    }

    #[test]
    fn a_glued_note_reference_ends_at_its_label() {
        let html = "<p>Texto<a href=\"notes.xhtml#n1\">1</a>. Depois.</p>";
        assert_eq!(html_to_text_projection(html).0, "Texto1. Depois.");
        assert_eq!(note_positions(html)[0].end, "Texto1".chars().count());
    }
}
