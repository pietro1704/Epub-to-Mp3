use super::native_tts_adapters::{native_registry, worker_from_failure};
use super::{
    playback_chunk_delivery::dispatch_playback_chunk_at_generation, ConversionRequest,
    ConversionWorker, ProgressEvent, WorkerError,
};
use crate::tts_session::*;
use std::{
    fs,
    path::Path,
    sync::{atomic::Ordering, Mutex},
};

impl ConversionWorker {
    #[cfg(test)]
    pub(super) fn synthesize_preferences(
        &self,
        request: &ConversionRequest,
        preferences: &crate::tts_preferences::TtsPreferences,
        text: &str,
        out: &Path,
        source_index: usize,
        language: Option<&str>,
        stale: &std::sync::atomic::AtomicBool,
        providers: &Mutex<Vec<crate::tts_preferences::TtsSelection>>,
        total: usize,
    ) -> Result<(), WorkerError> {
        let generation = self
            .control
            .as_ref()
            .and_then(|control| control.listening_plan())
            .map(|plan| plan.generation);
        self.synthesize_preferences_at_generation(
            request,
            preferences,
            text,
            out,
            source_index,
            language,
            stale,
            providers,
            total,
            generation,
            &[],
            &[],
            None,
        )
    }

    pub(super) fn synthesize_preferences_at_generation(
        &self,
        request: &ConversionRequest,
        preferences: &crate::tts_preferences::TtsPreferences,
        text: &str,
        out: &Path,
        source_index: usize,
        language: Option<&str>,
        stale: &std::sync::atomic::AtomicBool,
        providers: &Mutex<Vec<crate::tts_preferences::TtsSelection>>,
        total: usize,
        generation: Option<u64>,
        paragraph_ends: &[usize],
        heading_ends: &[usize],
        spoken_chapter: Option<&crate::epub::footnote_narration::SpokenChapter>,
    ) -> Result<(), WorkerError> {
        use std::io::Write;
        preferences
            .validate(language)
            .map_err(WorkerError::InvalidSelection)?;
        let mut output = fs::File::create(out)?;
        let mut policy = self.segment_policy.lock().expect("segment policy lock");
        // The first short utterance becomes playable before the rest of the chapter.
        let registry = native_registry(self, request).map_err(worker_from_failure)?;
        let descriptors = registry.descriptors();
        let limit = std::iter::once(&preferences.primary)
            .chain(preferences.secondary.iter())
            .filter_map(|selection| {
                let selection = SessionSelection::from_legacy(selection).ok()?;
                descriptors
                    .iter()
                    .find(|descriptor| {
                        descriptor.provider == selection.provider
                            && descriptor.runtime == selection.runtime
                    })
                    .map(|descriptor| descriptor.capabilities.max_text_chars)
            })
            .min()
            .unwrap_or(800)
            .min(800);
        if limit == 0 {
            return Err(WorkerError::Unsupported(
                "Synthesis adapter has an empty text capacity".into(),
            ));
        }
        let (source_offset, language_passages, mut forced_boundaries) = self
            .plan_language_passages(
                request,
                text,
                paragraph_ends,
                heading_ends,
                source_index,
                language,
            );
        // A narrated footnote starts and ends on a segment boundary so its pause is exact.
        let note_edges: &[usize] = spoken_chapter.map_or(&[], |chapter| &chapter.note_edges);
        forced_boundaries.extend(note_edges.iter().copied());
        forced_boundaries.sort_unstable();
        forced_boundaries.dedup();
        let mut segments = std::collections::VecDeque::from(
            self.pronunciation
                .source_plan(
                    text,
                    180.min(limit),
                    limit,
                    paragraph_ends,
                    &forced_boundaries,
                )
                .map_err(worker_from_failure)?,
        );
        // A playback request holds background work until its first segment is published.
        let mut foreground = self
            .streaming_chunk
            .is_some()
            .then(crate::conversion_control::hold_foreground);
        let mut sessions = self.tts_sessions.lock().expect("TTS session lock");
        let mut resolved_sessions = Vec::new();
        let mut segment_receipts = Vec::new();
        let mut index = 0;
        let segment_cache =
            super::segment_audio_cache::SegmentAudioCache::new(&self.config.paths.cache_dir);
        let book_identity = self
            .source_identity
            .lock()
            .expect("source identity lock")
            .clone();
        while let Some(segment) = segments.pop_front() {
            let passage_language = super::language_routing::language_for_segment(
                &language_passages,
                segment.scalar_range.clone(),
                language,
                source_index,
                source_offset,
            )?;
            // A passage in a language the selected voices cannot speak (and with no language-
            // compatible secondary) is read with the book's main voice: playback never stops
            // mid-way for lack of a model. Which models are missing is known up front, from the
            // book profile, and installing one stays an explicit action.
            let routed =
                crate::language::preferences_for_language(preferences, Some(passage_language));
            let language = if crate::language::selection_supports_language(
                &routed.primary,
                passage_language,
            ) {
                Some(passage_language)
            } else {
                crate::diagnostic!(
                    "no voice for {passage_language}: reading this passage with the book's main voice ({})",
                    language.unwrap_or("default")
                );
                language.or(Some(passage_language))
            };
            let routed_preferences = if language == Some(passage_language) {
                routed
            } else {
                crate::language::preferences_for_language(preferences, language)
            };
            let preferences = &routed_preferences;
            let cache_hit = std::cell::Cell::new(false);
            let segment_started = std::time::Instant::now();
            if self.cancel.is_cancelled() {
                return Err(WorkerError::Cancelled);
            }
            if stale.load(Ordering::Acquire)
                || self.control.as_ref().is_some_and(|control| {
                    !control.generation_is_current(generation) || control.preempts(source_index)
                })
            {
                return Err(WorkerError::PlaybackWindowChanged);
            }
            // Streaming playback outranks background jobs: rest while a seek is being served.
            crate::conversion_control::wait_for_foreground(
                self.streaming_chunk.is_some()
                    || self
                        .control
                        .as_ref()
                        .is_some_and(|control| control.is_streaming()),
                &|| self.cancel.is_cancelled(),
                crate::conversion_control::FOREGROUND_MAX_WAIT,
            );
            if self.cancel.is_cancelled() {
                return Err(WorkerError::Cancelled);
            }
            // Commit policy changes only for a validated, accepted segment.
            // A cancelled/stale secondary must not consume recovery counters.
            let mut attempt =
                RecoveryAttempt::new(&policy, preferences, self.platform_tts.is_some())
                    .map_err(worker_from_failure)?;
            let renderer = super::segment_synthesis::SegmentSynthesis {
                worker: self,
                request,
                preferences,
                registry: &registry,
                language: language.unwrap_or("pt-BR"),
                stale,
                generation,
                source_index,
                structure: super::heading_pauses::Structure::new(
                    text,
                    heading_ends,
                    paragraph_ends,
                )
                .with_note_edges(note_edges),
                book_identity: book_identity.as_deref(),
                segment_cache: &segment_cache,
            };
            let mut synthesize = |selection: &crate::tts_preferences::TtsSelection,
                                  source_segment: &SourceTextSegment|
             -> Result<Vec<u8>, TtsFailure> {
                cache_hit.set(false);
                let (bytes, cached) = renderer.render(&mut sessions, selection, source_segment)?;
                cache_hit.set(cached);
                Ok(bytes)
            };
            // A real, useful segment is the health probe. Attempts are serial
            // under the policy lock; no second voice or throwaway audio runs
            // in parallel. Native fallback covers only a short passage before
            // we reconsider the preferred providers.
            let mut attempt_selection = |selection: &crate::tts_preferences::TtsSelection| -> Result<
                (Vec<u8>, Vec<SourceTextSegment>),
                TtsFailure,
            > {
                if selection.engine == "system" && selection != &preferences.primary {
                    let paragraph_ends = segment.relative_paragraph_ends(paragraph_ends);
                    let mut passages = self.pronunciation.source_plan(
                        &segment.source,
                        if index == 0 { 60 } else { 240 },
                        240,
                        &paragraph_ends,
                        &segment.relative_paragraph_ends(heading_ends),
                    )?;
                    for passage in &mut passages {
                        passage.rebase(&segment);
                    }
                    let first = passages.remove(0);
                    Ok((synthesize(selection, &first)?, passages))
                } else {
                    Ok((synthesize(selection, &segment)?, Vec::new()))
                }
            };
            let mut fallback_cause = None;
            let (bytes, remainder) = loop {
                match attempt_selection(attempt.selection()) {
                    Ok(audio) => break audio,
                    Err(failure) => {
                        fallback_cause = Some(failure.clone());
                        if let Err(terminal) = attempt.failed(&failure) {
                            return Err(super::language_routing::recovery_failure(
                                terminal,
                                language,
                                attempt.selection().model_id.as_deref(),
                            ));
                        }
                    }
                }
            };
            let selection = attempt.selection().clone();
            let fallback_used = attempt.fallback_used();
            // Source coordinates belong to this occurrence, never the reusable
            // audio cache. Equal text elsewhere in a chapter has a new anchor.
            let consumed_end = remainder
                .first()
                .map_or(segment.byte_range.end, |next| next.byte_range.start);
            let spoken = text[segment.byte_range.start..consumed_end].trim();
            let base = source_offset;
            let leading = segment
                .source
                .chars()
                .take_while(|c| c.is_whitespace())
                .count();
            let scalar_start = segment.scalar_range.start + leading;
            let bytes = match spoken_chapter
                .map(|chapter| chapter.binding(scalar_start..scalar_start + spoken.chars().count()))
            {
                // Spoken layer: the audio points back to the source (the note body while a
                // note is read) instead of assuming the spoken text is the source text.
                Some(Some(crate::epub::footnote_narration::Binding::Source { offset })) => {
                    crate::speech_alignment::bind_source(bytes, spoken, offset)
                }
                Some(Some(crate::epub::footnote_narration::Binding::Note { number, source })) => {
                    crate::speech_alignment::bind_note(
                        bytes,
                        spoken,
                        crate::speech_alignment::NoteBinding {
                            number,
                            source_start: source.start,
                            source_end: source.end,
                        },
                    )
                }
                Some(None) => bytes,
                None => crate::speech_alignment::bind_source(bytes, spoken, base + scalar_start),
            };
            if self
                .control
                .as_ref()
                .is_some_and(|control| !control.generation_is_current(generation))
            {
                return Err(WorkerError::PlaybackWindowChanged);
            }
            if !dispatch_playback_chunk_at_generation(
                self.control.as_ref(),
                self.streaming_chunk.as_ref(),
                source_index,
                index,
                &bytes,
                stale,
                generation,
            ) {
                return Err(if stale.load(Ordering::Acquire) {
                    WorkerError::PlaybackWindowChanged
                } else {
                    WorkerError::Cancelled
                });
            }
            output.write_all(&bytes)?;
            if let Some(control) = &self.control {
                control.note_segment_done(source_index);
            }
            drop(foreground.take());
            let consumed_chars = remainder
                .first()
                .map_or(segment.scalar_range.end, |next| next.scalar_range.start)
                - segment.scalar_range.start;
            self.render_progress
                .lock()
                .expect("render progress lock")
                .segment(
                    source_index,
                    consumed_chars,
                    segment_started.elapsed().as_secs_f64(),
                    cache_hit.get(),
                );
            if let Some(control) = &self.control {
                if !cache_hit.get() {
                    control.observe_generation_at(
                        generation,
                        segment_started.elapsed().as_secs_f64(),
                        consumed_chars,
                    );
                }
            }
            for passage in remainder.into_iter().rev() {
                segments.push_front(passage);
            }
            index += 1;
            *policy = attempt.accepted();
            let session_key = (
                request.job_id.clone(),
                language.unwrap_or("pt-BR").to_owned(),
                serde_json::to_string(&selection).expect("selection serialization"),
            );
            let identity = sessions
                .get(&session_key)
                .expect("accepted session")
                .identity()
                .clone();
            segment_receipts.push(SynthesisReceipt {
                version: CONTRACT_VERSION,
                session_id: format!("{}:{}", request.job_id, self.tts_session_epoch),
                source_index,
                segment_index: index - 1,
                identity: identity.clone(),
                format: AudioFormat::Mp3,
                fallback_cause,
            });
            if !resolved_sessions.contains(&identity) {
                resolved_sessions.push(identity.clone());
            }
            if fallback_used {
                self.fallback_chapters
                    .lock()
                    .expect("fallback chapter lock")
                    .insert(source_index);
            }
            let mut actual_selection = selection.clone();
            actual_selection.voice = identity.selection.voice.clone();
            if actual_selection.session.is_some() {
                actual_selection.session = Some(identity.selection.clone());
            }
            let mut used = providers.lock().expect("provider lock");
            if !used.contains(&actual_selection) {
                used.push(actual_selection.clone());
            }
            self.emit(ProgressEvent {
                render_progress: None,
                job_id: request.job_id.clone(),
                state: "running".into(),
                chapter_index: Some(source_index),
                chapters_total: total,
                chapters_completed: 0,
                percent: 0.0,
                engine: Some(selection.engine.clone()),
                model_id: selection.model_id.clone(),
                voice: actual_selection.voice.clone(),
                fallback_used,
                message: format!(
                    "Using {} for segment {}",
                    if selection.engine == "system" {
                        self.platform_tts
                            .as_ref()
                            .map(|p| p.backend_name())
                            .unwrap_or("system")
                    } else {
                        &selection.engine
                    },
                    index
                ),
            });
        }
        output.sync_all()?;
        crate::cache::atomic_write_json(
            out.with_extension("tts-sessions.json"),
            &resolved_sessions,
        )?;
        crate::cache::atomic_write_json(
            out.with_extension("tts-receipts.json"),
            &segment_receipts,
        )?;
        Ok(())
    }
}
