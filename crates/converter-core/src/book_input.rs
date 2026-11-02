//! Source dispatch shared by metadata inspection and actual conversion.
use crate::{
    epub::{self, Book},
    ingestion::{pdf_text::PdfTextIngestion, IngestionError},
};
use std::path::Path;

#[derive(Debug, thiserror::Error)]
pub enum BookInputError {
    #[error(transparent)]
    Io(#[from] std::io::Error),
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

/// Metadata inspection preserves seekable EPUB reads instead of buffering assets.
pub fn parse_book_reader<R: std::io::Read + std::io::Seek>(
    path: &Path,
    reader: R,
) -> Result<Book, BookInputError> {
    if is_pdf(path) {
        let source = read_pdf_source(reader)?;
        Ok(PdfTextIngestion::from_bytes(path, &source)?)
    } else {
        Ok(epub::parse_epub(reader)?)
    }
}

/// Conversion hashes the immutable source bytes; PDF reads remain bounded.
pub fn read_book_source(path: &Path) -> Result<Vec<u8>, BookInputError> {
    if is_pdf(path) {
        read_pdf_source(std::fs::File::open(path)?)
    } else {
        Ok(std::fs::read(path)?)
    }
}

fn is_pdf(path: &Path) -> bool {
    path.extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("pdf"))
}

pub(crate) fn read_pdf_source<R: std::io::Read + std::io::Seek>(
    mut reader: R,
) -> Result<Vec<u8>, BookInputError> {
    use std::io::{Read, SeekFrom};
    let limit = crate::ingestion::pdf_text::MAX_SOURCE_BYTES;
    let length = reader.seek(SeekFrom::End(0))?;
    let too_large = || {
        BookInputError::Pdf(IngestionError::InvalidInput {
            message: "PDF exceeds the 256 MiB input limit".into(),
        })
    };
    if length > limit as u64 {
        return Err(too_large());
    }
    reader.seek(SeekFrom::Start(0))?;
    let mut source = Vec::new();
    reader.take(limit as u64 + 1).read_to_end(&mut source)?;
    if source.len() > limit {
        return Err(too_large());
    }
    Ok(source)
}
