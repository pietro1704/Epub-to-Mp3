//! Explicit source-format ingestion boundaries for the Rust migration.
//!
//! PDF keeps the current server semantics at the boundary: text-layer pages are
//! supported, while OCR remains an explicit unsupported capability until the
//! Rust OCR dependency and cache contract are selected. MOBI/AZW extraction is
//! likewise intentionally unsupported until a KindleUnpack-compatible crate is
//! selected; silently treating either format as EPUB would change behavior.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceFormat {
    Pdf,
    Mobi,
    Azw,
    Azw3,
}

impl SourceFormat {
    pub fn from_path(path: &Path) -> Option<Self> {
        match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
            "pdf" => Some(Self::Pdf),
            "mobi" => Some(Self::Mobi),
            "azw" => Some(Self::Azw),
            "azw3" => Some(Self::Azw3),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngestionChapter {
    pub index: String,
    pub name: String,
    pub source_path: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngestedBook {
    pub title: String,
    pub author: String,
    pub chapters: Vec<IngestionChapter>,
    pub source_format: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IngestionError {
    UnsupportedFormat { format: SourceFormat, path: PathBuf },
    MissingDependency { dependency: &'static str },
    InvalidInput { message: String },
    ExtractionFailed { message: String },
    NoReadableText,
}

impl std::fmt::Display for IngestionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedFormat { format, .. } => write!(f, "unsupported {:?} ingestion adapter", format),
            Self::MissingDependency { dependency } => write!(f, "missing ingestion dependency: {dependency}"),
            Self::InvalidInput { message } | Self::ExtractionFailed { message } => f.write_str(message),
            Self::NoReadableText => f.write_str("no readable text could be extracted"),
        }
    }
}

impl std::error::Error for IngestionError {}

/// Adapter boundary for the supported portion of PDF ingestion.
///
/// The PDF parser itself is deliberately not guessed here. The Python
/// implementation uses `pypdf` plus optional Vision OCR. Rust callers must
/// provide a selected PDF dependency/implementation before extraction is
/// enabled, and must preserve one chapter per page, page labels, metadata, and
/// the no-readable-text error.
pub trait PdfIngestionAdapter {
    fn ingest_pdf(&self, path: &Path) -> Result<IngestedBook, IngestionError>;
}

/// Adapter boundary for MOBI/AZW/AZW3 ingestion.
///
/// Current behavior delegates to KindleUnpack via the Python `mobi` package,
/// then parses extracted EPUB or HTML. No Rust crate is selected yet, so these
/// formats fail explicitly rather than being misclassified as EPUB.
pub trait MobiIngestionAdapter {
    fn ingest_mobi(&self, path: &Path, format: SourceFormat) -> Result<IngestedBook, IngestionError>;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct UnsupportedPdfAdapter;

impl PdfIngestionAdapter for UnsupportedPdfAdapter {
    fn ingest_pdf(&self, path: &Path) -> Result<IngestedBook, IngestionError> {
        Err(IngestionError::MissingDependency { dependency: "Rust PDF text extraction adapter (pypdf-compatible)" })
            .map_err(|error| match error {
                IngestionError::MissingDependency { .. } => IngestionError::UnsupportedFormat {
                    format: SourceFormat::Pdf,
                    path: path.to_path_buf(),
                },
                other => other,
            })
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct UnsupportedMobiAdapter;

impl MobiIngestionAdapter for UnsupportedMobiAdapter {
    fn ingest_mobi(&self, path: &Path, format: SourceFormat) -> Result<IngestedBook, IngestionError> {
        Err(IngestionError::UnsupportedFormat { format, path: path.to_path_buf() })
    }
}

pub fn ingest_non_epub(
    path: &Path,
    pdf: &impl PdfIngestionAdapter,
    mobi: &impl MobiIngestionAdapter,
) -> Result<IngestedBook, IngestionError> {
    match SourceFormat::from_path(path) {
        Some(SourceFormat::Pdf) => pdf.ingest_pdf(path),
        Some(format @ (SourceFormat::Mobi | SourceFormat::Azw | SourceFormat::Azw3)) => {
            mobi.ingest_mobi(path, format)
        }
        None => Err(IngestionError::InvalidInput {
            message: format!("unsupported or missing source extension: {}", path.display()),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifies_supported_non_epub_extensions_case_insensitively() {
        assert_eq!(SourceFormat::from_path(Path::new("book.PDF")), Some(SourceFormat::Pdf));
        assert_eq!(SourceFormat::from_path(Path::new("book.mobi")), Some(SourceFormat::Mobi));
        assert_eq!(SourceFormat::from_path(Path::new("book.AZW3")), Some(SourceFormat::Azw3));
        assert_eq!(SourceFormat::from_path(Path::new("book.epub")), None);
    }

    #[test]
    fn default_adapters_fail_explicitly_without_guessing() {
        let path = Path::new("book.mobi");
        let result = ingest_non_epub(path, &UnsupportedPdfAdapter, &UnsupportedMobiAdapter);
        assert_eq!(
            result,
            Err(IngestionError::UnsupportedFormat {
                format: SourceFormat::Mobi,
                path: path.to_path_buf(),
            })
        );
    }
}
