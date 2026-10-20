use converter_core::{
    pcm::validate_mp3,
    text::normalise_whitespace,
    tts_preferences::{SegmentPolicy, TtsPreferences},
};
use serde_json::{json, Value};
use wasm_bindgen::prelude::*;

/// Browser binding for Rust-owned segment ordering, provider policy and artifacts.
#[wasm_bindgen]
pub struct ConversionSession {
    preferences: TtsPreferences,
    segments: Vec<(usize, String)>,
    cursor: usize,
    policy: SegmentPolicy,
    secondary: bool,
    cancelled: bool,
    audio: Vec<u8>,
    chapter_ready: bool,
}

#[wasm_bindgen]
impl ConversionSession {
    #[wasm_bindgen(constructor)]
    pub fn new(
        chapters_json: &str,
        preferences_json: &str,
        language: &str,
    ) -> Result<Self, JsValue> {
        let preferences: TtsPreferences = serde_json::from_str(preferences_json).map_err(error)?;
        preferences.validate(Some(language)).map_err(error)?;
        // Browser system speech is listening-only and cannot supply MP3 bytes.
        preferences
            .primary
            .validate(Some(language))
            .map_err(error)?;
        let chapters: Vec<Value> = serde_json::from_str(chapters_json).map_err(error)?;
        let mut segments = Vec::new();
        for chapter in chapters {
            let index = chapter["index"]
                .as_u64()
                .ok_or_else(|| error("Missing chapter index"))? as usize;
            let text = normalise_whitespace(chapter["text"].as_str().unwrap_or_default());
            let mut chunk = String::new();
            for word in text.split_whitespace() {
                let limit = if segments.is_empty() { 120 } else { 480 };
                if !chunk.is_empty() && chunk.chars().count() + word.chars().count() > limit {
                    segments.push((index, std::mem::take(&mut chunk)));
                }
                if !chunk.is_empty() {
                    chunk.push(' ');
                }
                chunk.push_str(word);
            }
            if !chunk.is_empty() {
                segments.push((index, chunk));
            }
        }
        Ok(Self {
            preferences,
            segments,
            cursor: 0,
            policy: SegmentPolicy::default(),
            secondary: false,
            cancelled: false,
            audio: Vec::new(),
            chapter_ready: false,
        })
    }

    pub fn next_segment(&self) -> Result<String, JsValue> {
        if self.cancelled {
            return Err(error("Conversion cancelled"));
        }
        if self.chapter_ready {
            return Err(error("Collect the completed chapter before advancing"));
        }
        let Some((chapter, text)) = self.segments.get(self.cursor) else {
            return Ok("null".into());
        };
        let selection = if self.secondary {
            self.preferences.secondary.as_ref().unwrap()
        } else {
            &self.preferences.primary
        };
        Ok(json!({"chapter": chapter, "index": self.cursor, "total": self.segments.len(), "text": text, "selection": selection, "fallback_used": self.secondary}).to_string())
    }

    pub fn provider_failed(&mut self) -> Result<(), JsValue> {
        if self.secondary {
            return Err(error("Secondary provider failed"));
        }
        self.policy
            .primary_failed(self.cancelled, self.preferences.secondary.is_some())
            .map_err(error)?;
        self.secondary = true;
        Ok(())
    }

    /// Accept bounded MP3 encoded by the shared Rust codec.
    pub fn accept_audio(&mut self, audio: &[u8]) -> Result<bool, JsValue> {
        if self.cancelled {
            return Err(error("Conversion cancelled"));
        }
        if self.chapter_ready || self.cursor >= self.segments.len() {
            return Err(error("No segment is awaiting audio"));
        }
        validate_mp3(audio).map_err(error)?;
        self.audio.extend_from_slice(audio);
        if !self.secondary {
            self.policy.primary_succeeded();
        }
        self.secondary = false;
        let previous = self.segments[self.cursor].0;
        self.cursor += 1;
        self.chapter_ready = self.segments.get(self.cursor).map(|s| s.0) != Some(previous);
        Ok(self.chapter_ready)
    }

    pub fn chapter_audio(&mut self) -> Result<Vec<u8>, JsValue> {
        if self.cancelled {
            return Err(error("Conversion cancelled"));
        }
        if !self.chapter_ready {
            return Err(error("Chapter audio is incomplete"));
        }
        self.chapter_ready = false;
        Ok(std::mem::take(&mut self.audio))
    }

    pub fn cancel(&mut self) {
        self.cancelled = true;
        self.audio.clear();
    }
}

fn error(message: impl ToString) -> JsValue {
    JsValue::from_str(&message.to_string())
}
