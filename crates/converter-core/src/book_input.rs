//! Source dispatch shared by metadata inspection and actual conversion.
use crate::{
    epub::{self, Book},
    ingestion::{pdf_text::PdfTextIngestion, IngestionError},
};
use std::path::Path;

#[derive(Debug, thiserror::Error)]
pub enum BookInputError {
    #[error(transparent)]
    Epub(#[from] epub::EpubError),
    #[error(transparent)]
    Pdf(#[from] IngestionError),
}

pub fn parse_book_source(path: &Path, source: &[u8]) -> Result<Book, BookInputError> {
    parse_book_source_with_cancel(path, source, &|| false)
}

pub fn parse_book_source_with_cancel(
    path: &Path,
    source: &[u8],
    cancelled: &dyn Fn() -> bool,
) -> Result<Book, BookInputError> {
    if path
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("pdf"))
    {
        Ok(PdfTextIngestion::from_bytes_with_cancel(
            path, source, cancelled,
        )?)
    } else {
        Ok(epub::parse_epub(std::io::Cursor::new(source))?)
    }
}

/// PDF front matter is retained, but must not be claimed as mapped source TOC.
pub fn verify_book_source(path: &Path, book: &Book) -> crate::structure::StructureVerification {
    use crate::structure::{StructureSource, StructureWarning};
    let mut result = crate::structure::verify_epub_toc(book);
    if !path
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("pdf"))
        || book.toc.is_empty()
    {
        return result;
    }
    fn mapped(items: &[crate::toc::TocItem], path: &str) -> bool {
        items
            .iter()
            .any(|item| item.href == path || mapped(&item.children, path))
    }
    for chapter in &book.chapters {
        if !chapter.text.trim().is_empty() && !mapped(&book.toc, &chapter.source_path) {
            result.warnings.push(StructureWarning {
                code: "PDF_CONTENT_OUTSIDE_TOC",
                message: format!(
                    "Readable source content at {} is outside the PDF outline",
                    chapter.source_path
                ),
            });
            result.verified = false;
            result.source = StructureSource::SourceFallback;
        }
    }
    result
}
