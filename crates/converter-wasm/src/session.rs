use converter_core::{
    text::normalise_whitespace,
    tts_preferences::{SegmentPolicy, TtsPreferences},
    tts_session::{
        normalize_audio, AudioFormat, FailureKind, RecoveryAttempt, SynthesisReceipt, TtsFailure,
        CONTRACT_VERSION,
    },
};
use serde_json::{json, Value};
use wasm_bindgen::prelude::*;

/// Browser binding for Rust-owned segment ordering, provider policy and artifacts.
#[wasm_bindgen]
pub struct ConversionSession {
    language: String,
    session_id: String,
    preferences: TtsPreferences,
    segments: Vec<(usize, String)>,
    cursor: usize,
    policy: SegmentPolicy,
    attempt: RecoveryAttempt,
    cancelled: bool,
    audio: Vec<u8>,
    chapter_ready: bool,
    policy_restored: bool,
    source_chapters: Vec<(usize, String)>,
    listening: Option<converter_core::tts_session::ListeningPlan>,
    text_limit: usize,
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
        let mut selected =
            converter_core::tts_session::SessionSelection::from_legacy(&preferences.primary)
                .map_err(error)?;
        let descriptor = converter_core::tts_session::builtin_descriptors()
            .into_iter()
            .find(|descriptor| {
                descriptor.provider == selected.provider
                    && descriptor.targets.iter().any(|target| target == "web")
                    && descriptor.capabilities.audio_bytes
                    && (preferences.primary.session.is_none()
                        || descriptor.runtime == selected.runtime)
            })
            .ok_or_else(|| error("The selected provider has no browser audio-byte runtime"))?;
        if preferences.primary.session.is_none() {
            selected.runtime = descriptor.runtime.clone();
        }
        selected.validate(&descriptor, language).map_err(error)?;
        let mut segments = Vec::new();
        let mut source_chapters = Vec::new();
        for chapter in chapters {
            let index = chapter["index"]
                .as_u64()
                .ok_or_else(|| error("Missing chapter index"))? as usize;
            let text = normalise_whitespace(chapter["text"].as_str().unwrap_or_default());
            let limit = descriptor.capabilities.max_text_chars.min(800);
            let chunks = converter_core::tts_session::segment_text(&text, limit.min(180), limit)
                .map_err(error)?;
            source_chapters.push((index, text));
            segments.extend(chunks.into_iter().map(|chunk| (index, chunk)));
        }
        let attempt =
            RecoveryAttempt::new(&SegmentPolicy::default(), &preferences, false).map_err(error)?;
        Ok(Self {
            language: language.into(),
            session_id: converter_core::tts_session::new_session_id(),
            preferences,
            segments,
            cursor: 0,
            policy: SegmentPolicy::default(),
            attempt,
            cancelled: false,
            audio: Vec::new(),
            chapter_ready: false,
            policy_restored: false,
            source_chapters,
            listening: None,
            text_limit: descriptor.capabilities.max_text_chars.min(800),
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
        if self
            .listening
            .as_ref()
            .is_some_and(|plan| !plan.permits(*chapter))
        {
            return Ok(json!({"waiting": true}).to_string());
        }
        let selection = self.attempt.selection();
        Ok(json!({"session_id": self.session_id, "chapter": chapter, "index": self.cursor, "total": self.segments.len(), "text": text, "selection": selection, "fallback_used": self.attempt.fallback_used()}).to_string())
    }

    pub fn policy_state_json(&self) -> Result<String, JsValue> {
        serde_json::to_string(&self.policy).map_err(error)
    }

    pub fn restore_policy_state_json(&mut self, state: &str) -> Result<(), JsValue> {
        if self.cancelled
            || self.cursor != 0
            || self.chapter_ready
            || !self.audio.is_empty()
            || self.policy_restored
            || self.attempt.fallback_used()
        {
            return Err(error(
                "Recovery state can only be restored before starting a session",
            ));
        }
        let policy: SegmentPolicy = serde_json::from_str(state).map_err(error)?;
        let attempt = RecoveryAttempt::new(&policy, &self.preferences, false).map_err(error)?;
        self.policy = policy;
        self.attempt = attempt;
        self.policy_restored = true;
        Ok(())
    }

    pub fn provider_failed(&mut self) -> Result<(), JsValue> {
        if self.cancelled {
            return Err(error("Conversion cancelled"));
        }
        if self.chapter_ready || self.cursor >= self.segments.len() {
            return Err(error("No segment is awaiting audio"));
        }
        self.attempt
            .failed(&TtsFailure::new(FailureKind::Synthesis, "Provider failed"))
            .map_err(error)
    }

    /// Legacy byte acceptance is retained for captured, unversioned jobs only.
    pub fn accept_audio(&mut self, audio: &[u8]) -> Result<bool, JsValue> {
        if self.listening.is_some()
            || self.preferences.primary.session.is_some()
            || self
                .preferences
                .secondary
                .as_ref()
                .is_some_and(|selection| selection.session.is_some())
        {
            return Err(error("Version 2 selections require an audio receipt"));
        }
        self.accept_audio_internal(audio)
    }

    pub fn accept_audio_v2(&mut self, audio: &[u8], receipt_json: &str) -> Result<bool, JsValue> {
        if self.cancelled {
            return Err(error("Conversion cancelled"));
        }
        let receipt: SynthesisReceipt = serde_json::from_str(receipt_json).map_err(error)?;
        let requested = self.attempt.selection();
        let resolved = &receipt.identity.selection;
        let descriptor = converter_core::tts_session::builtin_descriptors()
            .into_iter()
            .find(|descriptor| {
                descriptor.provider == resolved.provider
                    && descriptor.runtime == resolved.runtime
                    && descriptor.targets.iter().any(|target| target == "web")
                    && descriptor.capabilities.audio_bytes
            });
        if descriptor
            .as_ref()
            .is_none_or(|descriptor| descriptor.revision != receipt.identity.runtime_revision)
        {
            return Err(error("Audio receipt has an unavailable runtime identity"));
        }
        resolved
            .validate(
                descriptor.as_ref().expect("validated runtime"),
                &self.language,
            )
            .map_err(error)?;
        if let Some(id) = &resolved.model_id {
            let model = converter_core::model_catalog::MODELS
                .iter()
                .find(|model| model.id == id)
                .ok_or_else(|| error("Audio receipt has an unknown model"))?;
            if resolved.model_revision.is_none()
                || receipt.identity.artifacts.len() != model.artifacts.len()
                || model.artifacts.iter().any(|artifact| {
                    receipt
                        .identity
                        .artifacts
                        .get(artifact.name)
                        .map(String::as_str)
                        != Some(artifact.sha256)
                })
            {
                return Err(error(
                    "Audio receipt does not match the model artifact identity",
                ));
            }
        }
        if receipt.version != CONTRACT_VERSION
            || receipt.session_id != self.session_id
            || resolved.version != CONTRACT_VERSION
            || receipt.segment_index != self.cursor
            || self.segments.get(self.cursor).map(|segment| segment.0) != Some(receipt.source_index)
            || receipt.format != AudioFormat::Mp3
            || resolved.provider != requested.engine
            || resolved.model_id != requested.model_id
            || requested
                .voice
                .as_ref()
                .is_some_and(|voice| resolved.voice.as_ref() != Some(voice))
            || requested.session.as_ref().is_some_and(|session| {
                session.runtime != resolved.runtime
                    || session.model_revision != resolved.model_revision
                    || session.options != resolved.options
            })
        {
            return Err(error(
                "Audio receipt does not match the pending segment selection",
            ));
        }
        self.accept_audio_internal(audio)
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

    pub fn set_listening_position_json_v2(&mut self, position_json: &str) -> Result<(), JsValue> {
        if self.cancelled {
            return Err(error("Conversion cancelled"));
        }
        let position: converter_core::tts_session::ListeningPosition =
            serde_json::from_str(position_json).map_err(error)?;
        let source = self
            .source_chapters
            .iter()
            .find(|(chapter, _)| *chapter == position.chapter_index)
            .ok_or_else(|| error("Listening chapter is outside this job selection"))?;
        let mut plan = self.listening.clone().unwrap_or(
            converter_core::tts_session::ListeningPlan::new(position.clone()).map_err(error)?,
        );
        plan.move_to(position.clone()).map_err(error)?;
        plan.remaining_text(source.0, &source.1).map_err(error)?;
        let mut segments = Vec::new();
        for (chapter, text) in &self.source_chapters {
            if *chapter < position.chapter_index {
                continue;
            }
            let (text, _) = plan.remaining_text(*chapter, text).map_err(error)?;
            segments.extend(
                converter_core::tts_session::segment_text(
                    text,
                    self.text_limit.min(180),
                    self.text_limit,
                )
                .map_err(error)?
                .into_iter()
                .map(|text| (*chapter, text)),
            );
        }
        self.listening = Some(plan);
        self.segments = segments;
        self.cursor = 0;
        self.audio.clear();
        self.chapter_ready = false;
        self.session_id = converter_core::tts_session::new_session_id();
        self.attempt =
            RecoveryAttempt::new(&self.policy, &self.preferences, false).map_err(error)?;
        Ok(())
    }

    pub fn playback_feedback_json_v2(&mut self, feedback_json: &str) -> Result<(), JsValue> {
        if self.cancelled {
            return Err(error("Conversion cancelled"));
        }
        let feedback = serde_json::from_str(feedback_json).map_err(error)?;
        self.listening
            .as_mut()
            .ok_or_else(|| error("No listening position selected"))?
            .feedback(&feedback)
            .map_err(error)
    }

    pub fn listening_generation_v2(&self) -> u64 {
        self.listening
            .as_ref()
            .map_or(u64::MAX, |plan| plan.generation)
    }

    pub fn observe_generation_v2(&mut self, seconds: f64, text_chars: usize) {
        if let Some(plan) = &mut self.listening {
            plan.observe_generation(seconds, text_chars);
        }
    }
    pub fn audio_duration_seconds_v2(&self, audio: &[u8]) -> Result<f64, JsValue> {
        converter_core::pcm::mp3_duration_seconds(audio).map_err(error)
    }

    pub fn skip_cached_chapter_v2(&mut self, chapter: usize) -> Result<(), JsValue> {
        if self.cancelled
            || self.chapter_ready
            || !self.audio.is_empty()
            || self.segments.get(self.cursor).map(|segment| segment.0) != Some(chapter)
        {
            return Err(error(
                "Cached chapter cannot replace an active segment transaction",
            ));
        }
        while self
            .segments
            .get(self.cursor)
            .is_some_and(|segment| segment.0 == chapter)
        {
            self.cursor += 1;
        }
        Ok(())
    }
}

impl ConversionSession {
    fn accept_audio_internal(&mut self, audio: &[u8]) -> Result<bool, JsValue> {
        if self.cancelled {
            return Err(error("Conversion cancelled"));
        }
        if self.chapter_ready || self.cursor >= self.segments.len() {
            return Err(error("No segment is awaiting audio"));
        }
        let audio = normalize_audio(&AudioFormat::Mp3, audio).map_err(error)?;
        let policy = self.attempt.clone().accepted();
        let next = RecoveryAttempt::new(&policy, &self.preferences, false).map_err(error)?;
        self.policy = policy;
        self.attempt = next;
        self.audio.extend_from_slice(&audio);
        let previous = self.segments[self.cursor].0;
        self.cursor += 1;
        self.chapter_ready = self.segments.get(self.cursor).map(|s| s.0) != Some(previous);
        Ok(self.chapter_ready)
    }
}

fn error(message: impl ToString) -> JsValue {
    JsValue::from_str(&message.to_string())
}
