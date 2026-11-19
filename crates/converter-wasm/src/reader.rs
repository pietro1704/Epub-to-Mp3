//! Additive reader boundary. The shared core owns all EPUB and markup rules.
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn reader_inspect_epub_json_v1(bytes: &[u8]) -> Result<String, JsValue> {
    converter_core::reader::inspect_epub_json(bytes)
        .map_err(|error| JsValue::from_str(&error.to_string()))
}

#[wasm_bindgen]
pub fn reader_chapter_json_v1(request_json: &str) -> Result<String, JsValue> {
    converter_core::reader::chapter_json(request_json)
        .map_err(|error| JsValue::from_str(&error.to_string()))
}
