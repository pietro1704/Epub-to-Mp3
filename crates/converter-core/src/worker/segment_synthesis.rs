//! Render one source segment through its prepared provider and immutable audio cache.
use super::{segment_audio_cache::SegmentAudioCache, ConversionRequest, ConversionWorker};
use crate::{
    platform_tts,
    tts_preferences::{TtsPreferences, TtsSelection},
    tts_session::*,
};
use std::{
    collections::BTreeMap,
    sync::atomic::{AtomicBool, Ordering},
};

pub(super) type PreparedSessions = BTreeMap<(String, String, String), Box<dyn TtsSession>>;

pub(super) struct SegmentSynthesis<'a> {
    pub worker: &'a ConversionWorker,
    pub request: &'a ConversionRequest,
    pub preferences: &'a TtsPreferences,
    pub registry: &'a TtsRegistry,
    pub language: &'a str,
    pub stale: &'a AtomicBool,
    pub generation: Option<u64>,
    pub source_index: usize,
    pub structure: super::heading_pauses::Structure<'a>,
    pub book_identity: Option<&'a str>,
    pub segment_cache: &'a SegmentAudioCache,
}

impl SegmentSynthesis<'_> {
    /// The boolean records an actual cache hit, never inferred from file existence.
    pub fn render(
        &self,
        sessions: &mut PreparedSessions,
        selection: &TtsSelection,
        source_segment: &SourceTextSegment,
    ) -> Result<(Vec<u8>, bool), TtsFailure> {
        let segment = source_segment.speech();
        let boundary = super::heading_pauses::boundary_after(source_segment, &self.structure);
        let pause = super::heading_pauses::pause_millis(boundary, &selection.engine);

        let context = SynthesisContext {
            language: self.language,
            cancelled: &|| self.worker.cancel.is_cancelled(),
            replaced: &|| {
                self.stale.load(Ordering::Acquire)
                    || self.worker.control.as_ref().is_some_and(|control| {
                        !control.generation_is_current(self.generation)
                            || !control.chapter_is_in_playback_window(self.source_index)
                    })
            },
        };
        context.check()?;
        let key = (
            self.request.job_id.clone(),
            context.language.to_owned(),
            serde_json::to_string(selection).expect("selection serialization"),
        );
        let selected = SessionSelection::from_legacy(selection)?;
        let descriptors = self.registry.descriptors();
        let descriptor = descriptors
            .iter()
            .find(|descriptor| {
                descriptor.provider == selected.provider && descriptor.runtime == selected.runtime
            })
            .ok_or_else(|| {
                TtsFailure::new(FailureKind::Unavailable, "No registered synthesis adapter")
            })?;
        if descriptor.capabilities.online
            && selection != &self.preferences.primary
            && !self.preferences.allow_online_fallback
        {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Online fallback requires explicit permission",
            ));
        }
        if !sessions.contains_key(&key) {
            let session = self.registry.prepare(&selected, context.language)?;
            sessions.insert(key.clone(), session);
        }
        let session = sessions.get_mut(&key).expect("prepared session");
        let spoken = self.worker.pronunciation.apply(segment);
        if spoken.chars().count()
            > segment
                .chars()
                .count()
                .saturating_mul(8)
                .saturating_add(400)
        {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Pronunciation expansion exceeds the bounded speech limit",
            ));
        }
        let segment_key = self.book_identity.and_then(|book| {
            // Only rules that change this block invalidate its inner cache.
            let speech_identity = super::heading_pauses::speech_identity(segment, &spoken, pause);
            super::segment_audio_cache::key(
                book,
                context.language,
                &speech_identity,
                session.identity(),
                self.preferences.silence_trim,
            )
        });
        if !self.worker.execution_options.force_reprocess
            && !self.worker.execution_options.clear_cache
        {
            if let Some(bytes) = segment_key
                .as_deref()
                .and_then(|key| self.segment_cache.load(key))
            {
                context.check()?;
                return Ok((bytes, true));
            }
        }
        let format = descriptor
            .capabilities
            .audio_formats
            .first()
            .cloned()
            .ok_or_else(|| {
                TtsFailure::new(FailureKind::Unavailable, "Adapter has no audio-byte format")
            })?;
        let mut encoded = Vec::new();
        let speech_limit = descriptor.capabilities.max_text_chars.min(800);
        let passages = if spoken.chars().count() <= speech_limit {
            vec![spoken]
        } else {
            platform_tts::segments_with_limit(&spoken, speech_limit)?
        };
        for passage in passages {
            let mut sink = AudioSink::new(format.clone(), MAX_SEGMENT_BYTES)
                .with_silence_trim(self.preferences.silence_trim);
            if let Err(failure) = session.synthesize(&passage, &context, &mut sink) {
                sessions.remove(&key);
                return Err(failure);
            }
            context.check()?;
            encoded.extend(sink.into_mp3()?);
            if encoded.len() > MAX_SEGMENT_BYTES {
                return Err(TtsFailure::new(
                    FailureKind::InvalidAudio,
                    "Expanded pronunciation exceeds segment limit",
                ));
            }
        }
        super::heading_pauses::append(&mut encoded, pause, &context)?;
        context.check()?;
        if let Some(key) = segment_key {
            let _lease = self
                .worker
                .control
                .as_ref()
                .map(|control| control.lease_generation(self.generation, Some(self.source_index)))
                .transpose()
                .map_err(|_| TtsFailure::new(FailureKind::Replaced, "Playback window changed"))?;
            let _ = self.segment_cache.store(&key, &encoded);
        }
        Ok((encoded, false))
    }
}
