//! Cross-platform validation of source chapter structure.

use crate::{epub::Book, toc::TocItem};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StructureSource {
    Toc,
    SourceFallback,
    Heuristic,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StructureWarning {
    pub code: &'static str,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StructureVerification {
    pub source: StructureSource,
    pub verified: bool,
    pub warnings: Vec<StructureWarning>,
    pub mapped_toc_items: usize,
    pub total_toc_items: usize,
}

impl StructureVerification {
    pub fn requires_confirmation(&self) -> bool {
        !self.warnings.is_empty()
    }
}

/// Validate the TOC against the chapters extracted from the source document.
///
/// This deliberately reports problems instead of silently replacing the TOC.
/// Client adapters can then display the warnings and choose a source fallback.
pub fn verify_epub_toc(book: &Book) -> StructureVerification {
    let mut entries = Vec::new();
    flatten(&book.toc, &mut entries);
    let mut warnings = Vec::new();
    let mut mapped = 0;

    for item in &entries {
        let href = item.href.split('#').next().unwrap_or_default();
        let found = !href.is_empty()
            && book.chapters.iter().any(|chapter| {
                chapter.source_path.ends_with(href)
                    || chapter.source_path.ends_with(href.trim_start_matches("./"))
            });
        if found {
            mapped += 1;
        } else {
            warnings.push(StructureWarning {
                code: "TOC_ITEM_UNMAPPED",
                message: format!("TOC item '{}' does not map to readable content", item.title),
            });
        }
    }

    if entries.is_empty() {
        warnings.push(StructureWarning {
            code: "TOC_MISSING",
            message: "No readable table of contents was found".into(),
        });
    }
    if book.chapters.is_empty() {
        warnings.push(StructureWarning {
            code: "NO_CHAPTERS",
            message: "The source produced no readable chapters".into(),
        });
    }

    StructureVerification {
        source: if warnings.is_empty() {
            StructureSource::Toc
        } else {
            StructureSource::SourceFallback
        },
        verified: warnings.is_empty(),
        warnings,
        mapped_toc_items: mapped,
        total_toc_items: entries.len(),
    }
}

fn flatten<'a>(items: &'a [TocItem], output: &mut Vec<&'a TocItem>) {
    for item in items {
        output.push(item);
        flatten(&item.children, output);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::epub::Chapter;

    fn book(toc: Vec<TocItem>, chapters: Vec<Chapter>) -> Book {
        Book {
            title: "Book".into(),
            author: String::new(),
            language: None,
            chapters,
            toc,
            cover: None,
            cover_mime: None,
        }
    }

    #[test]
    fn verifies_all_toc_items_that_map_to_source_chapters() {
        let result = verify_epub_toc(&book(
            vec![TocItem {
                title: "One".into(),
                href: "text/chapter.xhtml#start".into(),
                level: 1,
                children: Vec::new(),
            }],
            vec![Chapter {
                index: "1".into(),
                name: "One".into(),
                source_path: "text/chapter.xhtml".into(),
                text: "Readable".into(),
                level: 1,
            }],
        ));
        assert!(result.verified);
        assert_eq!(result.mapped_toc_items, 1);
        assert!(!result.requires_confirmation());
    }

    #[test]
    fn reports_missing_toc_and_requires_confirmation() {
        let result = verify_epub_toc(&book(Vec::new(), Vec::new()));
        assert!(!result.verified);
        assert!(result.requires_confirmation());
        assert_eq!(result.warnings[0].code, "TOC_MISSING");
    }
}
