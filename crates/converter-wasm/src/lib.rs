use std::io::{BufReader, Cursor};

use converter_core::epub::parse_epub;
use serde_json::json;
use wasm_bindgen::prelude::*;
mod session;
pub use session::ConversionSession;

#[wasm_bindgen]
pub fn tts_catalog_json_v2() -> String {
    converter_core::tts_session::catalog_json()
}

#[wasm_bindgen]
pub fn tts_request_cache_material_v2(
    source: &str,
    language: &str,
    preferences_json: &str,
    identities_json: &str,
) -> Result<String, JsValue> {
    let error = |error: serde_json::Error| JsValue::from_str(&error.to_string());
    let preferences = serde_json::from_str(preferences_json).map_err(error)?;
    let identities: Vec<String> = serde_json::from_str(identities_json).map_err(error)?;
    converter_core::tts_session::request_cache_material(
        source,
        Some(language),
        &preferences,
        &identities,
    )
    .map_err(|error| JsValue::from_str(&error.to_string()))
}

#[wasm_bindgen]
pub fn encode_pcm_f32_mp3(samples: &[f32], sample_rate: u32) -> Result<Vec<u8>, JsValue> {
    converter_core::tts_session::encode_pcm_f32(samples, sample_rate)
        .map_err(|error| JsValue::from_str(&error.to_string()))
}

/// The browser provider supplies bounded PCM WAV; the shared Rust codec owns MP3.
#[wasm_bindgen]
pub fn encode_wav_mp3(bytes: &[u8]) -> Result<Vec<u8>, JsValue> {
    converter_core::pcm::encode_wav_mp3(bytes).map_err(|error| JsValue::from_str(&error))
}

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
