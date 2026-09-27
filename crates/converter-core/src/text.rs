//! Text normalization and structural speech cues shared by conversion clients.

use std::collections::HashSet;

/// Collapse horizontal whitespace and trim the input, matching Python's
/// `normalise_whitespace` (newlines are intentionally preserved).
pub fn normalise_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pending_space = false;
    for ch in text.trim().chars() {
        if matches!(ch, ' ' | '\t' | '\n' | '\r' | '\x0c' | '\x0b') {
            pending_space = true;
        } else {
            if pending_space && !out.is_empty() {
                out.push(' ');
            }
            pending_space = false;
            out.push(ch);
        }
    }
    out
}

/// Remove common EPUB export prefixes such as `part0001` from chapter names.
pub fn clean_chapter_title(title: &str) -> String {
    let cleaned = normalise_whitespace(title);
    let bytes = cleaned.as_bytes();
    if bytes.len() >= 7 && cleaned[..4].eq_ignore_ascii_case("part")
        && bytes[4..].iter().take_3().all(|b| b.is_ascii_digit())
    {
        let mut pos = 7;
        while pos < bytes.len() && matches!(bytes[pos], b' ' | b'\t' | b'-' | 0xe2) {
            pos += 1;
        }
        let rest = cleaned[pos..].trim_start_matches(['-', '–', ':', ' ']);
        if !rest.is_empty() { return rest.to_string(); }
    }
    cleaned
}

fn structural_key(text: &str) -> String {
    text.chars().flat_map(|c| c.to_lowercase()).map(|c| {
        if c.is_alphanumeric() || c == '_' || c.is_whitespace() { c } else { ' ' }
    }).collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ")
}

fn first_lines(text: &str, limit: usize) -> Vec<String> {
    text.lines().filter_map(|line| {
        let line = normalise_whitespace(line);
        (!line.is_empty()).then_some(line)
    }).take(limit).collect()
}

fn strip_tags(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_tag = false;
    for ch in text.chars() {
        match ch { '<' => in_tag = true, '>' => in_tag = false, _ if !in_tag => out.push(ch), _ => {} }
    }
    out
}

fn html_titles(raw_html: &str) -> Vec<String> {
    let lower = raw_html.to_lowercase();
    let mut titles = Vec::new();
    let mut seen = HashSet::new();
    let mut scan = |open: &str, close: &str| {
        let mut at = 0;
        while let Some(start) = lower[at..].find(open) {
            let start = at + start + open.len();
            let Some(end) = lower[start..].find(close) else { break };
            let title = normalise_whitespace(&strip_tags(&raw_html[start..start + end]));
            if !title.is_empty() && seen.insert(title.to_lowercase()) { titles.push(title); }
            at = start + end + close.len();
        }
    };
    for n in 1..=6 { scan(&format!("<h{}", n), &format!("</h{}>", n)); }
    let mut at = 0;
    while let Some(start) = lower[at..].find("<p") {
        let start = at + start;
        let Some(body) = lower[start..].find('>') else { break };
        let body_start = start + body + 1;
        let Some(end) = lower[body_start..].find("</p>") else { break };
        let title = normalise_whitespace(&strip_tags(&raw_html[body_start..body_start + end]));
        if !title.is_empty() && title.split_whitespace().count() <= 8 && !title.ends_with(['.', '!', '?']) {
            if seen.insert(title.to_lowercase()) { titles.push(title); }
        } else if !lower[start..].contains("<h") { break; }
        at = body_start + end + 4;
        if titles.len() >= 6 { break; }
    }
    titles
}

/// Apply chapter announcements, structural title pauses, and numeric marker cleanup.
pub fn apply_structural_speech_cues(text: &str, raw_html: Option<&str>, chapter_title: Option<&str>) -> String {
    if text.is_empty() { return String::new(); }
    let mut result = text.to_string();
    let mut titles = raw_html.map(html_titles).unwrap_or_default();
    let toc = clean_chapter_title(chapter_title.unwrap_or(""));
    if !toc.is_empty() && !titles.iter().any(|t| t.eq_ignore_ascii_case(&toc)) { titles.push(toc.clone()); }
    if titles.is_empty() { return result; }
    let first = first_lines(&result, 1).pop().unwrap_or_default();
    let opening = first_lines(&result, 4).join(" ");
    let first_key = structural_key(&first);
    let toc_key = structural_key(&toc);
    let substantive = toc_key.len() >= 10 && toc_key.split_whitespace().count() >= 2;
    if !toc_key.is_empty() && first_key != toc_key && !(substantive && {
        let opening_key = structural_key(&opening);
        opening_key.starts_with(&toc_key) || toc_key.starts_with(&opening_key) || opening_key.contains(&toc_key)
    }) { result = format!("{}\n{}", toc, result); }
    let keys: HashSet<String> = titles.iter().map(|t| t.to_lowercase()).collect();
    result = result.lines().map(|line| {
        let stripped = normalise_whitespace(line);
        if !stripped.is_empty() && keys.contains(&stripped.trim_end_matches(['.', '!', '?', ';', ':']).to_lowercase()) {
            format!("{}.", stripped.trim_end_matches(['.', '!', '?', ';', ':']))
        } else { line.to_string() }
    }).collect::<Vec<_>>().join("\n");
    result = result.lines().filter(|line| {
        let t = line.trim();
        !(t.parse::<u32>().is_ok() || t.strip_prefix("##").and_then(|x| x.trim().parse::<u32>().ok()).is_some() || t.split_once('|').map_or(false, |(n, rest)| n.trim().parse::<u32>().is_ok() && rest.trim().is_empty()))
    }).collect::<Vec<_>>().join("\n");
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn preserves_newlines_in_normalization() { assert_eq!(normalise_whitespace(" a\n\tb "), "a b"); }
    #[test] fn short_titles_are_announced() { assert!(apply_structural_speech_cues("The opening text.", Some("<h1>1</h1>"), Some("1")).starts_with("1\n")); }
    #[test] fn substantive_opening_title_is_not_duplicated() { assert!(!apply_structural_speech_cues("A Long Chapter Title\nBody.", Some("<h1>A Long Chapter Title</h1>"), Some("A Long Chapter Title")).starts_with("A Long Chapter Title\nA Long")); }
}
