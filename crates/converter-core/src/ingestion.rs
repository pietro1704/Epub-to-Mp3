//! Explicit source-format ingestion boundaries for the Rust migration.
//!
//! PDF keeps the current server semantics at the boundary: text-layer pages are
//! supported, while OCR remains an explicit unsupported capability until the
//! Rust OCR dependency and cache contract are selected. MOBI/AZW extraction is
//! likewise intentionally unsupported until a KindleUnpack-compatible crate is
//! selected; silently treating either format as EPUB would change behavior.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IngestionError {
    InvalidInput { message: String },
    ExtractionFailed { message: String },
    NoReadableText,
    Cancelled,
}

impl std::fmt::Display for IngestionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidInput { message } | Self::ExtractionFailed { message } => {
                f.write_str(message)
            }
            Self::Cancelled => f.write_str("PDF extraction cancelled"),
            Self::NoReadableText => f.write_str("no readable text could be extracted"),
        }
    }
}

impl std::error::Error for IngestionError {}

#[cfg(not(target_arch = "wasm32"))]
mod pdf_outline;
#[cfg(not(target_arch = "wasm32"))]
mod pdf_page_labels;
#[cfg(not(target_arch = "wasm32"))]
pub mod pdf_text;
