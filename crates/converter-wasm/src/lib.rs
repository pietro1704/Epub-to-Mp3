use std::io::{BufReader, Cursor};

use converter_core::epub::parse_epub;
use serde_json::json;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn health() -> String {
    "ok".to_owned()
}

/// Parse an EPUB supplied by the browser and return its book structure as JSON.
/// Audio synthesis remains a separate capability until a browser-safe backend
/// is wired into the shared Rust pipeline.
#[wasm_bindgen]
pub fn inspect_epub(bytes: &[u8]) -> Result<String, JsValue> {
    inspect_epub_json(bytes).map_err(|error| JsValue::from_str(&error))
}

fn inspect_epub_json(bytes: &[u8]) -> Result<String, String> {
    let book = parse_epub(BufReader::new(Cursor::new(bytes))).map_err(|error| error.to_string())?;
    let chapters: Vec<_> = book
        .chapters
        .iter()
        .map(|chapter| {
            json!({
                "index": chapter.index,
                "name": chapter.name,
                "sourcePath": chapter.source_path,
                "textChars": chapter.text.chars().count(),
                "text": chapter.text,
                "level": chapter.level,
            })
        })
        .collect();
    serde_json::to_string(&json!({
        "bookTitle": book.title,
        "bookAuthor": book.author,
        "language": book.language,
        "chapters": chapters,
    }))
    .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_health() {
        assert_eq!(health(), "ok");
    }

    #[test]
    fn rejects_invalid_epub() {
        assert!(inspect_epub_json(b"not-an-epub").is_err());
    }
}
