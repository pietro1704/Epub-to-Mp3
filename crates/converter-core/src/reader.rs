//! Bounded, platform-independent EPUB reader documents and presentation.
//! Only this module produces markup that embedded clients may render.
mod css;
mod layout;
mod markup;
mod matches;
mod resources;
mod text_axis;
mod types;

pub use types::*;

pub const MAX_EPUB_BYTES: usize = 100 * 1024 * 1024;
pub const MAX_CHAPTER_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_CSS_BYTES: usize = 256 * 1024;
pub const MAX_OUTPUT_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_NODES: usize = 50_000;
pub const MAX_DEPTH: usize = 128;
pub const MAX_MATCHES: usize = 10_000;

#[derive(Debug, thiserror::Error)]
pub enum ReaderError {
    #[error("Reader {kind} exceeds limit of {limit}")]
    Limit { kind: &'static str, limit: usize },
    #[error("Invalid reader input: {0}")]
    Invalid(String),
    #[error(transparent)]
    Epub(#[from] crate::epub::EpubError),
    #[error(transparent)]
    Archive(#[from] zip::result::ZipError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}
pub(crate) type Result<T> = std::result::Result<T, ReaderError>;

pub(crate) fn bounded(actual: usize, limit: usize, kind: &'static str) -> Result<()> {
    if actual > limit {
        Err(ReaderError::Limit { kind, limit })
    } else {
        Ok(())
    }
}

pub fn inspect_epub_json(bytes: &[u8]) -> Result<String> {
    encode(&resources::inspect(bytes)?)
}

pub fn chapter_json(request: &str) -> Result<String> {
    bounded(request.len(), MAX_CHAPTER_BYTES * 4, "request bytes")?;
    let request: ChapterRequest =
        serde_json::from_str(request).map_err(|error| ReaderError::Invalid(error.to_string()))?;
    encode(&render_chapter(request)?)
}

pub fn render_chapter(request: ChapterRequest) -> Result<ReaderChapter> {
    if request.version != 1 {
        return Err(ReaderError::Invalid("Unsupported reader version".into()));
    }
    bounded(request.text.len(), MAX_CHAPTER_BYTES, "fallback text bytes")?;
    bounded(request.search_text.len(), 4096, "search bytes")?;
    bounded(request.audio_text.len(), 64 * 1024, "audio text bytes")?;
    let stylesheet = request.css.as_deref().unwrap_or("");
    let document = match request
        .html
        .as_deref()
        .filter(|html| !html.trim().is_empty())
    {
        Some(html) => markup::sanitize(html, stylesheet)?,
        None => markup::fallback(&request.text, stylesheet)?,
    };
    layout::build(document, &request)
}

fn encode(value: &impl serde::Serialize) -> Result<String> {
    let json =
        serde_json::to_string(value).map_err(|error| ReaderError::Invalid(error.to_string()))?;
    bounded(json.len(), MAX_OUTPUT_BYTES, "serialized output bytes")?;
    Ok(json)
}

#[cfg(test)]
mod tests;
