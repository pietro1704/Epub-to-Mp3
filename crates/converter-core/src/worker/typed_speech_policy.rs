use super::native_tts_adapters::{worker_from_failure, NativeProvider};
use super::{
    playback_chunk_delivery::dispatch_playback_chunk_at_generation, ConversionRequest,
    ConversionWorker, ProgressEvent, WorkerError,
};
use crate::{platform_tts, tts_session::*};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{atomic::Ordering, Mutex},
};

impl ConversionWorker {
    pub(super) fn selection_model_paths(
        &self,
        request: &ConversionRequest,
        selection: &crate::tts_preferences::TtsSelection,
    ) -> (PathBuf, PathBuf) {
        let id = selection
            .model_id
            .as_deref()
            .unwrap_or(crate::tts_preferences::FABER_MODEL_ID);
        let explicit_selection = request.tts_preferences.as_ref().and_then(|preferences| {
            std::iter::once(&preferences.primary)
                .chain(preferences.secondary.iter())
                .find(|candidate| candidate.engine == "piper")
        });
        let explicit_applies = selection.engine == "piper"
            && explicit_selection.is_none_or(|candidate| candidate.model_id == selection.model_id);
        let model = if explicit_applies && request.piper_model.is_some() {
            request.piper_model.clone().expect("explicit model")
        } else if let Some(root) = &request.models_root {
            root.join(id).join("model.onnx")
        } else {
            self.config
                .paths
                .piper_models_dir
                .join(format!("{id}.onnx"))
        };
        let config = if explicit_applies && request.piper_config.is_some() {
            request.piper_config.clone().expect("explicit config")
        } else if let Some(root) = &request.models_root {
            root.join(id).join("model.onnx.json")
        } else {
            model.with_extension("onnx.json")
        };
        (model, config)
    }

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
    ) -> Result<(), WorkerError> {
        use std::io::Write;
        preferences.validate(language).map_err(WorkerError::Piper)?;
        let mut output = fs::File::create(out)?;
        let mut policy = self.segment_policy.lock().expect("segment policy lock");
        // The first short utterance becomes playable before the rest of the chapter.
        let descriptors: Vec<_> = self
            .tts_registry
            .descriptors()
            .into_iter()
            .chain(builtin_descriptors())
            .collect();
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
        let mut segments =
            std::collections::VecDeque::from(platform_tts::segments_with_limit(text, limit));
        let adapters: Vec<_> = builtin_descriptors()
            .into_iter()
            .filter(|descriptor| !descriptor.targets.iter().any(|target| target == "web"))
            .map(|descriptor| NativeProvider {
                worker: self,
                request,
                descriptor,
            })
            .collect();
        let mut sessions = self.tts_sessions.lock().expect("TTS session lock");
        let mut resolved_sessions = Vec::new();
        let mut segment_receipts = Vec::new();
        let mut index = 0;
        while let Some(segment) = segments.pop_front() {
            let segment_started = std::time::Instant::now();
            if self.cancel.is_cancelled() {
                return Err(WorkerError::Cancelled);
            }
            if stale.load(Ordering::Acquire)
                || self
                    .control
                    .as_ref()
                    .is_some_and(|control| !control.generation_is_current(generation))
            {
                return Err(WorkerError::PlaybackWindowChanged);
            }
            // Commit policy changes only for a validated, accepted segment.
            // A cancelled/stale secondary must not consume recovery counters.
            let mut attempt =
                RecoveryAttempt::new(&policy, preferences, self.platform_tts.is_some())
                    .map_err(worker_from_failure)?;
            let mut synthesize = |selection: &crate::tts_preferences::TtsSelection,
                                  segment: &str|
             -> Result<Vec<u8>, TtsFailure> {
                let context = SynthesisContext {
                    language: language.unwrap_or("pt-BR"),
                    cancelled: &|| self.cancel.is_cancelled(),
                    replaced: &|| {
                        stale.load(Ordering::Acquire)
                            || self.control.as_ref().is_some_and(|control| {
                                !control.generation_is_current(generation)
                                    || !control.chapter_is_in_playback_window(source_index)
                            })
                    },
                };
                context.check()?;
                let key = (
                    request.job_id.clone(),
                    context.language.to_owned(),
                    serde_json::to_string(selection).expect("selection serialization"),
                );
                let selected = SessionSelection::from_legacy(selection)?;
                let registered = self
                    .tts_registry
                    .descriptors()
                    .into_iter()
                    .find(|descriptor| {
                        descriptor.provider == selected.provider
                            && descriptor.runtime == selected.runtime
                    });
                let adapter = adapters.iter().find(|adapter| {
                    adapter.descriptor.provider == selected.provider
                        && adapter.descriptor.runtime == selected.runtime
                });
                let descriptor = registered
                    .as_ref()
                    .or_else(|| adapter.map(|adapter| &adapter.descriptor))
                    .ok_or_else(|| {
                        TtsFailure::new(FailureKind::Unavailable, "No registered synthesis adapter")
                    })?;
                if descriptor.capabilities.online
                    && selection != &preferences.primary
                    && !preferences.allow_online_fallback
                {
                    return Err(TtsFailure::new(
                        FailureKind::InvalidSelection,
                        "Online fallback requires explicit permission",
                    ));
                }
                if !sessions.contains_key(&key) {
                    let session = if registered.is_some() {
                        self.tts_registry.prepare(&selected, context.language)?
                    } else {
                        adapter
                            .ok_or_else(|| {
                                TtsFailure::new(
                                    FailureKind::Unavailable,
                                    "No registered synthesis adapter",
                                )
                            })?
                            .prepare(&selected, context.language)?
                    };
                    sessions.insert(key.clone(), session);
                }
                let session = sessions.get_mut(&key).expect("prepared session");
                let mut sink = AudioSink::new(
                    descriptor
                        .capabilities
                        .audio_formats
                        .first()
                        .cloned()
                        .ok_or_else(|| {
                            TtsFailure::new(
                                FailureKind::Unavailable,
                                "Adapter has no audio-byte format",
                            )
                        })?,
                    MAX_SEGMENT_BYTES,
                );
                if let Err(failure) = session.synthesize(segment, &context, &mut sink) {
                    sessions.remove(&key);
                    return Err(failure);
                }
                context.check()?;
                let encoded = sink.into_mp3();
                context.check()?;
                encoded
            };
            // A real, useful segment is the health probe. Attempts are serial
            // under the policy lock; no second voice or throwaway audio runs
            // in parallel. Native fallback covers only a short passage before
            // we reconsider the preferred providers.
            let mut attempt_selection = |selection: &crate::tts_preferences::TtsSelection|
                -> Result<(Vec<u8>, Vec<String>), TtsFailure> {
                if selection.engine == "system" && selection != &preferences.primary {
                    let mut passages = platform_tts::native_segments(&segment, index == 0);
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
                        attempt.failed(&failure).map_err(worker_from_failure)?;
                    }
                }
            };
            let selection = attempt.selection().clone();
            let fallback_used = attempt.fallback_used();
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
                let consumed_chars = segment
                    .chars()
                    .count()
                    .saturating_sub(
                        remainder
                            .iter()
                            .map(|passage| passage.chars().count())
                            .sum::<usize>(),
                    )
                    .max(1);
                control.observe_generation_at(
                    generation,
                    segment_started.elapsed().as_secs_f64(),
                    consumed_chars,
                );
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
