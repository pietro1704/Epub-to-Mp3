//! Text-layer PDF ingestion. OCR is a separate, explicit capability.
use super::{IngestedBook, IngestionChapter, IngestionError, PdfIngestionAdapter};
use crate::epub::{Book, Chapter};
use pdf_extract::{decode_text_string, Document, PlainTextOutput};
use std::path::Path;

pub(crate) const MAX_SOURCE_BYTES: usize = 256 * 1024 * 1024;

pub struct PdfTextIngestion;
impl PdfIngestionAdapter for PdfTextIngestion {
    fn ingest_pdf(&self, path: &Path) -> Result<IngestedBook, IngestionError> {
        let file = std::fs::File::open(path).map_err(extraction_error)?;
        let source = crate::book_input::read_pdf_source(file).map_err(|error| match error {
            crate::book_input::BookInputError::Pdf(error) => error,
            other => extraction_error(other),
        })?;
        let book = Self::from_bytes(path, &source)?;
        Ok(IngestedBook {
            title: book.title,
            author: book.author,
            chapters: book
                .chapters
                .into_iter()
                .map(|c| IngestionChapter {
                    index: c.index,
                    name: c.name,
                    source_path: c.source_path,
                    text: c.text,
                })
                .collect(),
            source_format: Some("pdf".into()),
        })
    }
}

impl PdfTextIngestion {
    pub fn from_bytes(path: &Path, source: &[u8]) -> Result<Book, IngestionError> {
        Self::from_bytes_with_cancel(path, source, &|| false)
    }

    pub fn from_bytes_with_cancel(
        path: &Path,
        source: &[u8],
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Book, IngestionError> {
        // The dependency has fallible-input paths implemented with panics. Do not
        // let malformed content unwind across the embedded C ABI boundary.
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            Self::extract(path, source, cancelled)
        }))
        .map_err(|_| extraction_error("malformed or unsupported PDF content"))?
    }

    fn extract(
        path: &Path,
        source: &[u8],
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Book, IngestionError> {
        if cancelled() {
            return Err(IngestionError::Cancelled);
        }
        if source.len() > MAX_SOURCE_BYTES {
            return Err(invalid("PDF exceeds the 256 MiB input limit"));
        }
        let mut doc = Document::load_mem(source).map_err(extraction_error)?;
        if doc.is_encrypted() {
            doc.decrypt("")
                .map_err(|_| invalid("This PDF requires a password before its text can be read"))?;
        }
        let pages = doc.get_pages();
        if pages.is_empty() || pages.len() > 20_000 {
            return Err(invalid(
                "PDF page count is empty or exceeds the 20000-page limit",
            ));
        }
        let labels = super::pdf_page_labels::labels(&doc, pages.len())?;
        let mut text = Vec::new();
        let mut total = 0usize;
        for (number, page_id) in &pages {
            if cancelled() {
                return Err(IngestionError::Cancelled);
            }
            let mut page = String::new();
            // Per-page extraction errors must never truncate a book silently.
            pdf_extract::output_doc_page(&doc, &mut PlainTextOutput::new(&mut page), *number)
                .map_err(extraction_error)?;
            page = page.trim().replace('\0', "");
            if page.is_empty() && has_drawn_content(&doc, *page_id)? {
                return Err(invalid(&format!("PDF page {number} contains graphics without selectable text; OCR is required before narration")));
            }
            total = total.saturating_add(page.len());
            if total > 32 * 1024 * 1024 {
                return Err(invalid("PDF extracted text exceeds the 32 MiB limit"));
            }
            text.push(page);
        }
        if text.iter().all(|page| page.trim().is_empty()) {
            return Err(IngestionError::NoReadableText);
        }
        if cancelled() {
            return Err(IngestionError::Cancelled);
        }
        let (toc, starts) = super::pdf_outline::structure(&doc, &pages)?;
        let mut chapters = Vec::new();
        let starts = if starts.is_empty() {
            (0..text.len())
                .map(|i| (i, format!("Page {}", labels[i]), 1))
                .collect()
        } else {
            starts
        };
        for (position, (start, title, level)) in starts.iter().enumerate() {
            let end = starts.get(position + 1).map_or(text.len(), |next| next.0);
            let content = text[*start..end].join("\n\n");
            let paragraph_ends = paragraph_ends(&content);
            chapters.push(Chapter {
                index: (position + 1).to_string(),
                name: title.clone(),
                source_path: format!("page-{}", start + 1),
                text: content,
                paragraph_ends,
                heading_ends: Vec::new(),
                level: *level,
            });
        }
        Ok(Book {
            title: info(&doc, b"Title")
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| {
                    path.file_stem()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned()
                }),
            author: info(&doc, b"Author").unwrap_or_default(),
            language: doc
                .catalog()
                .ok()
                .and_then(|cat| cat.get(b"Lang").ok())
                .and_then(|o| decode_text_string(o).ok()),
            chapters,
            toc,
            cover: None,
            cover_mime: None,
        })
    }
}
// Empty text on an XObject/inline-image page is not a known blank page.
// Refuse partial narration instead of silently skipping potentially scanned text.
fn has_drawn_content(doc: &Document, page: pdf_extract::ObjectId) -> Result<bool, IngestionError> {
    let bytes = doc.get_page_content(page).map_err(extraction_error)?;
    let content = pdf_extract::content::Content::decode(&bytes).map_err(extraction_error)?;
    Ok(content
        .operations
        .iter()
        .any(|operation| matches!(operation.operator.as_str(), "Do" | "BI")))
}

fn paragraph_ends(text: &str) -> Vec<usize> {
    let mut ends = Vec::new();
    let mut previous = false;
    for (i, ch) in text.chars().enumerate() {
        if ch == '\n' && !previous {
            ends.push(i);
        }
        previous = ch == '\n';
    }
    ends.push(text.chars().count());
    ends
}
fn info(doc: &Document, key: &[u8]) -> Option<String> {
    let value = doc.trailer.get(b"Info").ok()?;
    let dict = super::pdf_outline::dictionary(doc, value).ok()?;
    decode_text_string(dict.get(key).ok()?).ok()
}
pub(super) fn invalid(message: &str) -> IngestionError {
    IngestionError::InvalidInput {
        message: message.into(),
    }
}
fn extraction_error(error: impl std::fmt::Display) -> IngestionError {
    IngestionError::ExtractionFailed {
        message: format!("PDF text extraction failed: {error}"),
    }
}
