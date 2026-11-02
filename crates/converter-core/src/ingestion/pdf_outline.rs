//! Resolve PDF outline destinations without dropping invalid entries silently.
use super::{pdf_text::invalid, IngestionError};
use crate::toc::TocItem;
use pdf_extract::{decode_text_string, Dictionary, Document, Object, ObjectId};
use std::collections::{BTreeMap, HashSet};

type Starts = Vec<(usize, String, u32)>;
pub(super) fn dictionary<'a>(
    doc: &'a Document,
    value: &'a Object,
) -> Result<&'a Dictionary, IngestionError> {
    let mut value = value;
    let mut seen = HashSet::new();
    while let Object::Reference(id) = value {
        if !seen.insert(*id) {
            return Err(invalid("Cyclic PDF dictionary reference"));
        }
        value = doc
            .get_object(*id)
            .map_err(|_| invalid("Missing PDF dictionary reference"))?;
    }
    value
        .as_dict()
        .map_err(|_| invalid("Invalid PDF dictionary"))
}

pub(super) fn structure(
    doc: &Document,
    pages: &BTreeMap<u32, ObjectId>,
) -> Result<(Vec<TocItem>, Starts), IngestionError> {
    let catalog = doc
        .catalog()
        .map_err(|_| invalid("PDF catalog is missing"))?;
    let Ok(root) = catalog.get(b"Outlines") else {
        return Ok((Vec::new(), Vec::new()));
    };
    let root = dictionary(doc, root)?;
    let Ok(first) = root.get(b"First") else {
        return Ok((Vec::new(), Vec::new()));
    };
    let positions: BTreeMap<_, _> = pages.values().enumerate().map(|(i, id)| (*id, i)).collect();
    let mut parser = Parser {
        doc,
        positions,
        seen: HashSet::new(),
        starts: BTreeMap::new(),
        previous_page: None,
    };
    let toc = parser.walk(first, 1)?;
    if let Some((&page, _)) = parser.starts.first_key_value() {
        if page > 0 {
            parser.starts.insert(0, ("Front matter".into(), 1));
        }
    }
    Ok((
        toc,
        parser
            .starts
            .into_iter()
            .map(|(page, (title, level))| (page, title, level))
            .collect(),
    ))
}
struct Parser<'a> {
    doc: &'a Document,
    positions: BTreeMap<ObjectId, usize>,
    seen: HashSet<ObjectId>,
    starts: BTreeMap<usize, (String, u32)>,
    previous_page: Option<usize>,
}
impl Parser<'_> {
    fn walk(&mut self, first: &Object, level: u32) -> Result<Vec<TocItem>, IngestionError> {
        if level > 32 {
            return Err(invalid("PDF outline nesting exceeds 32 levels"));
        }
        let mut next = Some(first);
        let mut nodes = Vec::new();
        while let Some(value) = next {
            let id = value
                .as_reference()
                .map_err(|_| invalid("PDF outline nodes must be indirect references"))?;
            if self.seen.len() >= 20_000 || !self.seen.insert(id) {
                return Err(invalid("Cyclic or oversized PDF outline"));
            }
            let node = dictionary(self.doc, value)?;
            let title = node
                .get(b"Title")
                .ok()
                .and_then(|value| decode_text_string(value).ok())
                .filter(|s| !s.trim().is_empty())
                .ok_or_else(|| invalid("PDF outline title is missing"))?;
            let destination = if let Ok(dest) = node.get(b"Dest") {
                dest
            } else {
                let action = dictionary(
                    self.doc,
                    node.get(b"A")
                        .map_err(|_| invalid("PDF outline destination is missing"))?,
                )?;
                if action.get(b"S").and_then(Object::as_name).ok() != Some(b"GoTo".as_slice()) {
                    return Err(invalid("PDF outline destination is not a local page"));
                }
                action
                    .get(b"D")
                    .map_err(|_| invalid("PDF outline destination is missing"))?
            };
            let page = self.page(destination)?;
            if self.previous_page.is_some_and(|previous| page < previous) {
                return Err(invalid(
                    "PDF outline page order is not monotonic; review the source index",
                ));
            }
            self.previous_page = Some(page);
            self.starts
                .entry(page)
                .or_insert_with(|| (title.clone(), level));
            let children = if let Ok(first) = node.get(b"First") {
                self.walk(first, level + 1)?
            } else {
                Vec::new()
            };
            nodes.push(TocItem {
                title,
                href: format!("page-{}", page + 1),
                level,
                children,
            });
            next = node.get(b"Next").ok();
        }
        Ok(nodes)
    }
    fn page(&self, value: &Object) -> Result<usize, IngestionError> {
        let mut value = value;
        let mut seen = HashSet::new();
        loop {
            value = match value {
                Object::Reference(id) => {
                    if !seen.insert(*id) {
                        return Err(invalid("Cyclic PDF outline destination"));
                    }
                    self.doc
                        .get_object(*id)
                        .map_err(|_| invalid("PDF outline destination is missing"))?
                }
                Object::Name(name) | Object::String(name, _) => self.named(name)?,
                Object::Dictionary(dict) => dict
                    .get(b"D")
                    .map_err(|_| invalid("Invalid PDF named destination"))?,
                Object::Array(values) => {
                    let id = values
                        .first()
                        .and_then(|v| v.as_reference().ok())
                        .ok_or_else(|| invalid("PDF outline does not reference a page"))?;
                    return self.positions.get(&id).copied().ok_or_else(|| {
                        invalid("PDF outline references a page outside the document")
                    });
                }
                _ => return Err(invalid("Invalid PDF outline destination")),
            };
            if seen.len() > 32 {
                return Err(invalid("PDF outline destination nesting exceeds 32 levels"));
            }
            // Named destination cycles are bounded independently of indirect references.
            if matches!(value, Object::Name(_) | Object::String(_, _)) {
                return Err(invalid("Recursive PDF named destination"));
            }
        }
    }
    fn named(&self, name: &[u8]) -> Result<&Object, IngestionError> {
        let catalog = self
            .doc
            .catalog()
            .map_err(|_| invalid("PDF catalog is missing"))?;
        if let Ok(dests) = catalog.get(b"Dests") {
            if let Ok(value) = dictionary(self.doc, dests)?.get(name) {
                return Ok(value);
            }
        }
        let names = dictionary(
            self.doc,
            catalog
                .get(b"Names")
                .map_err(|_| invalid("PDF named destinations are missing"))?,
        )?;
        let root = names
            .get(b"Dests")
            .map_err(|_| invalid("PDF named destinations are missing"))?;
        let mut pending = vec![root];
        let mut visited = 0;
        while let Some(value) = pending.pop() {
            visited += 1;
            if visited > 20_000 {
                return Err(invalid("Cyclic or oversized PDF destination tree"));
            }
            let dict = dictionary(self.doc, value)?;
            if let Ok(names) = dict.get(b"Names").and_then(Object::as_array) {
                for pair in names.chunks_exact(2) {
                    if pair[0].as_str().ok() == Some(name) {
                        return Ok(&pair[1]);
                    }
                }
            }
            if let Ok(kids) = dict.get(b"Kids").and_then(Object::as_array) {
                pending.extend(kids);
            }
        }
        Err(invalid("PDF named destination was not found"))
    }
}
