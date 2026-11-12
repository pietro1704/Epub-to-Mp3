//! Column-major speech projection for confidently identified parallel translations.
//! Other tables and malformed/merged structures retain their original source order.
use quick_xml::{events::Event, Reader};
use std::borrow::Cow;

pub fn reading_order(html: &str) -> Cow<'_, str> {
    let mut reader = Reader::from_str(html);
    let mut replacements = Vec::new();
    let mut table = None;
    let mut depth = 0usize;
    let mut nested = false;
    let mut rows: Vec<Vec<std::ops::Range<usize>>> = Vec::new();
    let mut cell_start = None;
    let mut invalid = false;
    loop {
        let start = reader.buffer_position() as usize;
        match reader.read_event() {
            Ok(Event::Start(element)) => match element.local_name().as_ref() {
                b"table" => {
                    depth += 1;
                    if depth == 1 {
                        table = Some((
                            start,
                            element
                                .attributes()
                                .flatten()
                                .any(|a| a.key.as_ref() == b"dir" && a.value.as_ref() == b"rtl"),
                        ));
                        rows.clear();
                        nested = false;
                        invalid = false;
                    } else {
                        nested = true;
                    }
                }
                b"tr" if depth == 1 => rows.push(Vec::new()),
                b"td" | b"th" if depth == 1 => {
                    invalid |= element.attributes().flatten().any(|a| {
                        matches!(a.key.as_ref(), b"colspan" | b"rowspan")
                            && a.value.as_ref() != b"1"
                    });
                    cell_start = Some(start);
                }
                _ => {}
            },
            Ok(Event::End(element)) => match element.local_name().as_ref() {
                b"td" | b"th" if depth == 1 => {
                    if let (Some(start), Some(row)) = (cell_start.take(), rows.last_mut()) {
                        row.push(start..reader.buffer_position() as usize);
                    } else {
                        invalid = true;
                    }
                }
                b"table" if depth > 0 => {
                    depth -= 1;
                    if depth == 0
                        && !nested
                        && !invalid
                        && !rows.is_empty()
                        && rows.iter().all(|row| row.len() == 2)
                    {
                        let texts: Vec<String> = (0..2)
                            .map(|column| {
                                rows.iter()
                                    .map(|row| plain(&html[row[column].clone()]))
                                    .collect::<Vec<_>>()
                                    .join(" ")
                            })
                            .collect();
                        let languages: Vec<_> = texts
                            .iter()
                            .map(|text| crate::language::detect(text, None))
                            .collect();
                        if languages[0].is_some()
                            && languages[1].is_some()
                            && languages[0] != languages[1]
                        {
                            let (start, rtl) = table.take().expect("open table");
                            let mut replacement = String::from("<div>");
                            for column in if rtl { [1, 0] } else { [0, 1] } {
                                replacement.push_str("<div>");
                                for row in &rows {
                                    replacement.push_str(&html[row[column].clone()]);
                                }
                                replacement.push_str("</div>");
                            }
                            replacement.push_str("</div>");
                            replacements
                                .push((start..reader.buffer_position() as usize, replacement));
                        }
                    }
                }
                _ => {}
            },
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    if replacements.is_empty() {
        return Cow::Borrowed(html);
    }
    let mut result = html.to_owned();
    for (range, replacement) in replacements.into_iter().rev() {
        result.replace_range(range, &replacement);
    }
    Cow::Owned(result)
}

fn plain(html: &str) -> String {
    let mut reader = Reader::from_str(html);
    let mut text = String::new();
    loop {
        match reader.read_event() {
            Ok(Event::Text(value)) => {
                text.push_str(&String::from_utf8_lossy(value.as_ref()));
                text.push(' ');
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn translations_are_read_as_complete_columns_without_dropping_either_language() {
        let en = "The reader follows the story and discovers the beautiful country where their friends are waiting for the children. ".repeat(4);
        let pt = "O leitor acompanha a história e descobre o país maravilhoso onde seus amigos estão à espera das crianças. ".repeat(4);
        let html = format!("<table><tr><td>{en}LEFT1</td><td>{pt}RIGHT1</td></tr><tr><td>{en}LEFT2</td><td>{pt}RIGHT2</td></tr></table>");
        let result = reading_order(&html);
        assert!(result.find("LEFT2").unwrap() < result.find("RIGHT1").unwrap());
        for marker in ["LEFT1", "LEFT2", "RIGHT1", "RIGHT2"] {
            assert_eq!(result.matches(marker).count(), 1);
        }
    }
    #[test]
    fn ordinary_and_merged_tables_keep_their_order() {
        let html = "<table><tr><td>One</td><td>Two</td></tr></table>";
        assert_eq!(reading_order(html), html);
        let merged = "<table><tr><td colspan=\"2\">One</td></tr></table>";
        assert_eq!(reading_order(merged), merged);
    }
}
