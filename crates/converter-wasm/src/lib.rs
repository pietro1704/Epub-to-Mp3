use std::io::{BufReader, Cursor};

use converter_core::epub::parse_epub;
use serde_json::json;
use wasm_bindgen::prelude::*;
mod reader;
mod session;
pub use reader::{reader_chapter_json_v1, reader_inspect_epub_json_v1};
pub use session::ConversionSession;

#[wasm_bindgen]
pub fn tts_catalog_json_v2() -> String {
    converter_core::tts_session::catalog_json()
}

/// Base languages with at least one catalog model on `platform`
/// (`converter_tts_catalog_languages_json_v1`); `android_api` is 0 elsewhere.
#[wasm_bindgen]
pub fn tts_catalog_languages_json_v1(platform: &str, android_api: u32) -> Result<String, JsValue> {
    let platform = match platform.to_ascii_lowercase().as_str() {
        "android" => converter_core::model_catalog::ModelPlatform::Android,
        "ios" => converter_core::model_catalog::ModelPlatform::Ios,
        "macos" => converter_core::model_catalog::ModelPlatform::Macos,
        "linux" => converter_core::model_catalog::ModelPlatform::Linux,
        "windows" => converter_core::model_catalog::ModelPlatform::Windows,
        other => return Err(JsValue::from_str(&format!("unsupported platform: {other}"))),
    };
    let languages = converter_core::model_catalog::catalog_languages(
        platform,
        (android_api > 0).then_some(android_api),
    );
    Ok(serde_json::json!({ "schema_version": 1, "languages": languages }).to_string())
}

/// Resolves the narration for a book language (pure; never downloads). Same
/// contract as `converter_tts_resolve_language_model_json_v1`.
#[wasm_bindgen]
pub fn tts_resolve_language_model_json_v1(request_json: &str) -> Result<String, JsValue> {
    let error = |message: String| JsValue::from_str(&message);
    let request: converter_core::language_model_resolution::ResolutionRequest =
        serde_json::from_str(request_json).map_err(|e| error(e.to_string()))?;
    if request.schema_version != converter_core::language_model_resolution::SCHEMA_VERSION {
        return Err(error(format!(
            "unsupported language model request schema {}",
            request.schema_version
        )));
    }
    if request.book_language.trim().is_empty() {
        return Err(error("book_language must not be empty".into()));
    }
    serde_json::to_string(&converter_core::language_model_resolution::resolve(
        &request,
    ))
    .map_err(|e| error(e.to_string()))
}

#[wasm_bindgen]
pub fn tts_manual_catalog_json_v2() -> String {
    converter_core::tts_session::manual_catalog_json()
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
    fn rejects_invalid_epub() {
        assert!(inspect_epub_json(b"not-an-epub").is_err());
    }

    #[test]
    fn catalog_languages_lists_portuguese_for_the_browser_platform() {
        let json = tts_catalog_languages_json_v1("linux", 0).expect("languages");
        let value: serde_json::Value = serde_json::from_str(&json).expect("json");
        assert_eq!(value["schema_version"], 1);
        let tags: Vec<&str> = value["languages"]
            .as_array()
            .expect("array")
            .iter()
            .filter_map(|entry| entry["tag"].as_str())
            .collect();
        assert!(tags.contains(&"pt"), "{tags:?}");
        let mut sorted = tags.clone();
        sorted.sort_unstable();
        assert_eq!(tags, sorted, "languages are sorted by tag");
    }

    #[test]
    fn resolves_an_installed_model_without_downloading() {
        let request = serde_json::json!({
            "schema_version": 1,
            "book_language": "pt-BR",
            "installed_model_ids": ["pt_BR-faber-medium"],
            "platform": "Linux",
        })
        .to_string();
        let value: serde_json::Value =
            serde_json::from_str(&tts_resolve_language_model_json_v1(&request).expect("resolved"))
                .expect("json");
        assert_eq!(value["status"], "selected");
        assert_eq!(value["selection"]["model_id"], "pt_BR-faber-medium");
    }

    #[test]
    fn reports_a_missing_model_with_suggestions_for_an_uninstalled_language() {
        let request = serde_json::json!({
            "schema_version": 1,
            "book_language": "pt-BR",
            "allow_automatic_system_voice_fallback": false,
            "platform": "Linux",
        })
        .to_string();
        let value: serde_json::Value =
            serde_json::from_str(&tts_resolve_language_model_json_v1(&request).expect("resolved"))
                .expect("json");
        assert_eq!(value["status"], "missing_model");
        assert!(value["selection"].is_null());
        assert!(!value["missing"]["suggested"]
            .as_array()
            .expect("suggested")
            .is_empty());
    }
}
