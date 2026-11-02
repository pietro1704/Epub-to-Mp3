//! Preserve PageLabels number trees, including Roman front matter and prefixes.
use super::{pdf_outline::dictionary, pdf_text::invalid, IngestionError};
use pdf_extract::{decode_text_string, Document, Object};
use std::collections::BTreeMap;

pub(super) fn labels(doc: &Document, count: usize) -> Result<Vec<String>, IngestionError> {
    let catalog = doc
        .catalog()
        .map_err(|_| invalid("PDF catalog is missing"))?;
    let Ok(root) = catalog.get(b"PageLabels") else {
        return Ok((1..=count).map(|i| i.to_string()).collect());
    };
    let mut pending = vec![root];
    let mut ranges = BTreeMap::new();
    let mut visited = 0;
    while let Some(value) = pending.pop() {
        visited += 1;
        if visited > 20_000 {
            return Err(invalid("Cyclic or oversized PDF page-label tree"));
        }
        let node = dictionary(doc, value)?;
        if let Ok(nums) = node.get(b"Nums").and_then(Object::as_array) {
            if nums.len() % 2 != 0 {
                return Err(invalid("Invalid PDF page-label pairs"));
            }
            for pair in nums.chunks_exact(2) {
                let start = pair[0]
                    .as_i64()
                    .map_err(|_| invalid("Invalid PDF page-label index"))?;
                if start < 0 || start as usize >= count {
                    return Err(invalid("PDF page-label index is outside the document"));
                }
                if ranges
                    .insert(start as usize, dictionary(doc, &pair[1])?)
                    .is_some()
                {
                    return Err(invalid("Duplicate PDF page-label index"));
                }
            }
        }
        if let Ok(kids) = node.get(b"Kids").and_then(Object::as_array) {
            pending.extend(kids);
        }
    }
    (0..count)
        .map(|page| {
            let Some((&start, dict)) = ranges.range(..=page).next_back() else {
                return Ok((page + 1).to_string());
            };
            let prefix = dict
                .get(b"P")
                .ok()
                .map(decode_text_string)
                .transpose()
                .map_err(|_| invalid("Invalid PDF page-label prefix"))?
                .unwrap_or_default();
            if prefix.len() > 512 {
                return Err(invalid("PDF page-label prefix exceeds 512 bytes"));
            }
            let initial = dict
                .get(b"St")
                .ok()
                .map(Object::as_i64)
                .transpose()
                .map_err(|_| invalid("Invalid PDF page-label start"))?
                .unwrap_or(1);
            if !(1..=1_000_000).contains(&initial) {
                return Err(invalid(
                    "PDF page-label start is outside its supported range",
                ));
            }
            let number = initial as usize + page - start;
            let suffix = match dict
                .get(b"S")
                .ok()
                .map(Object::as_name)
                .transpose()
                .map_err(|_| invalid("Invalid PDF page-label style"))?
            {
                None => String::new(),
                Some(b"D") => number.to_string(),
                Some(b"r") => roman(number).to_lowercase(),
                Some(b"R") => roman(number),
                Some(b"a") => alphabetic(number, b'a'),
                Some(b"A") => alphabetic(number, b'A'),
                _ => return Err(invalid("Unsupported PDF page-label style")),
            };
            if suffix.len() > 4096 {
                return Err(invalid("PDF page label exceeds 4096 bytes"));
            }
            Ok(format!("{prefix}{suffix}"))
        })
        .collect()
}
fn roman(mut number: usize) -> String {
    let mut output = String::new();
    for (value, symbol) in [
        (1000, "M"),
        (900, "CM"),
        (500, "D"),
        (400, "CD"),
        (100, "C"),
        (90, "XC"),
        (50, "L"),
        (40, "XL"),
        (10, "X"),
        (9, "IX"),
        (5, "V"),
        (4, "IV"),
        (1, "I"),
    ] {
        while number >= value {
            output.push_str(symbol);
            number -= value;
        }
    }
    output
}
fn alphabetic(number: usize, start: u8) -> String {
    char::from(start + ((number - 1) % 26) as u8)
        .to_string()
        .repeat((number - 1) / 26 + 1)
}
