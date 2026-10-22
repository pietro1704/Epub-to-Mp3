use super::{
    default_edge_voice, dispatch_playback_chunk, run_preference_edge_synthesis, ConversionRequest,
    ConversionWorker, ProgressEvent, WorkerError,
};
use crate::{platform_tts, tts::EdgeError};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{atomic::Ordering, Arc, Mutex},
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
        if let Some(root) = &request.models_root {
            let directory = root.join(id);
            return (
                directory.join("model.onnx"),
                directory.join("model.onnx.json"),
            );
        }
        let model = request.piper_model.clone().unwrap_or_else(|| {
            self.config
                .paths
                .piper_models_dir
                .join(format!("{id}.onnx"))
        });
        let config = request
            .piper_config
            .clone()
            .unwrap_or_else(|| model.with_extension("onnx.json"));
        (model, config)
    }

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
        use std::io::Write;
        preferences.validate(language).map_err(WorkerError::Piper)?;
        let staging = tempfile::tempdir_in(out.parent().unwrap_or(Path::new(".")))?;
        let mut output = fs::File::create(out)?;
        let mut policy = self.segment_policy.lock().expect("segment policy lock");
        // The first short utterance becomes playable before the rest of the chapter.
        let mut segments = std::collections::VecDeque::from(platform_tts::segments(text));
        let system_selection = crate::tts_preferences::TtsSelection {
            engine: "system".into(),
            model_id: None,
            voice: None,
        };
        let mut index = 0;
        while let Some(segment) = segments.pop_front() {
            if self.cancel.is_cancelled() {
                return Err(WorkerError::Cancelled);
            }
            if stale.load(Ordering::Acquire) {
                return Err(WorkerError::PlaybackWindowChanged);
            }
            // Commit policy changes only for a validated, accepted segment.
            // A cancelled/stale secondary must not consume recovery counters.
            let mut pending_policy = policy.clone();
            let path = staging.path().join(format!("{index}.mp3"));
            let synthesize_unvalidated = |selection: &crate::tts_preferences::TtsSelection,
                                          segment: &str|
             -> Result<Vec<u8>, WorkerError> {
                if self.cancel.is_cancelled() {
                    return Err(WorkerError::Cancelled);
                }
                if stale.load(Ordering::Acquire) {
                    return Err(WorkerError::PlaybackWindowChanged);
                }
                selection.validate(language).map_err(WorkerError::Piper)?;
                if selection.engine == "system" {
                    let adapter = self.platform_tts.as_ref().ok_or_else(|| {
                        WorkerError::PlatformTts("No installed system speech adapter".into())
                    })?;
                    let _guard = loop {
                        if self.cancel.is_cancelled() {
                            return Err(WorkerError::Cancelled);
                        }
                        if stale.load(Ordering::Acquire) {
                            return Err(WorkerError::PlaybackWindowChanged);
                        }
                        match self.platform_gate.try_lock() {
                            Ok(guard) => break guard,
                            Err(std::sync::TryLockError::Poisoned(_)) => {
                                return Err(WorkerError::PlatformTts(
                                    "system speech lock poisoned".into(),
                                ))
                            }
                            Err(std::sync::TryLockError::WouldBlock) => {
                                std::thread::sleep(std::time::Duration::from_millis(25))
                            }
                        }
                    };
                    let started = std::time::Instant::now();
                    let deadline = std::time::Duration::from_secs(30);
                    let wav = path.with_extension("wav");
                    let cancelled = || {
                        self.cancel.is_cancelled()
                            || stale.load(Ordering::Acquire)
                            || started.elapsed() >= deadline
                    };
                    adapter
                        .synthesize_wav(segment, language.unwrap_or("pt-BR"), &wav, &cancelled)
                        .map_err(WorkerError::PlatformTts)?;
                    if started.elapsed() >= deadline {
                        return Err(WorkerError::PlatformTts(
                            "System speech deadline exceeded".into(),
                        ));
                    }
                    return platform_tts::encode_wav(&fs::read(wav)?)
                        .map_err(WorkerError::PlatformTts);
                }
                if selection.engine == "edge" {
                    #[cfg(test)]
                    if let Some(edge) = &self.test_edge {
                        return edge(segment);
                    }
                    return run_preference_edge_synthesis(
                        crate::tts::synthesize_with_reference_client(
                            segment,
                            selection
                                .voice
                                .as_deref()
                                .unwrap_or_else(|| default_edge_voice(language)),
                            Arc::clone(&self.adaptive),
                            self.telemetry.clone(),
                        ),
                        &self.cancel,
                        segment.len(),
                    );
                }
                let (model, config) = self.selection_model_paths(request, selection);
                let wav = path.with_extension("wav");
                self.synthesize_with_piper(segment, &wav, Some(&model), Some(&config))?;
                platform_tts::encode_wav(&fs::read(wav)?).map_err(WorkerError::PlatformTts)
            };
            let synthesize = |selection: &crate::tts_preferences::TtsSelection,
                              segment: &str|
             -> Result<Vec<u8>, WorkerError> {
                let result = synthesize_unvalidated(selection, segment);
                // Native inference may finish after cancellation was requested.
                // Never deliver those bytes or start a secondary provider afterward.
                if self.cancel.is_cancelled() {
                    return Err(WorkerError::Cancelled);
                }
                if stale.load(Ordering::Acquire) {
                    return Err(WorkerError::PlaybackWindowChanged);
                }
                let bytes = result?;
                platform_tts::validate_mp3(&bytes).map_err(WorkerError::PlatformTts)?;
                Ok(bytes)
            };
            // A real, useful segment is the health probe. Attempts are serial
            // under the policy lock; no second voice or throwaway audio runs
            // in parallel. Native fallback covers only a short passage before
            // we reconsider the preferred providers.
            let attempt_selection = |selection: &crate::tts_preferences::TtsSelection|
                -> Result<(Vec<u8>, Vec<String>), WorkerError> {
                if selection.engine == "system" && selection != &preferences.primary {
                    let mut passages = platform_tts::native_segments(&segment, index == 0);
                    let first = passages.remove(0);
                    Ok((synthesize(selection, &first)?, passages))
                } else {
                    Ok((synthesize(selection, &segment)?, Vec::new()))
                }
            };
            let terminal = |error: &WorkerError| {
                self.cancel.is_cancelled()
                    || stale.load(Ordering::Acquire)
                    || matches!(
                        error,
                        WorkerError::Cancelled
                            | WorkerError::PlaybackWindowChanged
                            | WorkerError::Edge(EdgeError::Cancelled)
                    )
            };
            let attempt = if pending_policy.should_try_primary(preferences) {
                attempt_selection(&preferences.primary)
            } else {
                Err(WorkerError::Piper("Primary recovery cooldown".into()))
            };
            let cooling_down = matches!(&attempt, Err(WorkerError::Piper(message)) if message == "Primary recovery cooldown");
            let retry_delay = |error: &WorkerError| match error {
                WorkerError::Edge(EdgeError::RateLimited { retry_after, .. }) => {
                    Some(retry_after.unwrap_or(std::time::Duration::from_secs(30)))
                }
                _ => None,
            };
            let (selection, bytes, remainder, fallback_used) = match attempt {
                Ok((bytes, remainder)) => {
                    pending_policy.primary_succeeded();
                    (&preferences.primary, bytes, remainder, false)
                }
                Err(error) => {
                    if terminal(&error) {
                        return Err(error);
                    }
                    if !cooling_down {
                        eprintln!("[Rust][TTS] primary failed: {error}");
                        pending_policy.provider_failed(false, preferences).map_err(
                            |policy_error| WorkerError::Piper(format!("{policy_error}: {error}")),
                        )?;
                        if preferences.continues_native() {
                            if let Some(delay) = retry_delay(&error) {
                                pending_policy.defer_primary_for(delay);
                            }
                        }
                    }
                    let secondary = preferences.secondary.as_ref();
                    let secondary_result = secondary.map(|selection| {
                        if pending_policy.should_try_secondary() {
                            attempt_selection(selection)
                        } else {
                            Err(WorkerError::Piper("Secondary recovery cooldown".into()))
                        }
                    });
                    match secondary_result {
                        Some(Ok((bytes, remainder))) => {
                            pending_policy.secondary_succeeded();
                            (secondary.unwrap(), bytes, remainder, true)
                        }
                        Some(Err(error)) if terminal(&error) => return Err(error),
                        failure
                            if preferences.continues_native()
                                && preferences.primary.engine != "system"
                                && secondary
                                    .map_or(true, |selection| selection.engine != "system") =>
                        {
                            if let Some(Err(error)) = failure {
                                if let Some(delay) = retry_delay(&error) {
                                    pending_policy.defer_secondary_for(delay);
                                }
                                eprintln!("[Rust][TTS] secondary failed: {error}; trying installed system voice");
                            }
                            let (bytes, remainder) = attempt_selection(&system_selection)?;
                            (&system_selection, bytes, remainder, true)
                        }
                        Some(Err(error)) => return Err(error),
                        None => return Err(error),
                    }
                }
            };
            if !dispatch_playback_chunk(
                self.control.as_ref(),
                self.streaming_chunk.as_ref(),
                source_index,
                index,
                &bytes,
                stale,
            ) {
                return Err(if stale.load(Ordering::Acquire) {
                    WorkerError::PlaybackWindowChanged
                } else {
                    WorkerError::Cancelled
                });
            }
            output.write_all(&bytes)?;
            for passage in remainder.into_iter().rev() {
                segments.push_front(passage);
            }
            index += 1;
            *policy = pending_policy;
            if fallback_used {
                self.fallback_chapters
                    .lock()
                    .expect("fallback chapter lock")
                    .insert(source_index);
            }
            let mut actual_selection = selection.clone();
            if actual_selection.engine == "edge" && actual_selection.voice.is_none() {
                actual_selection.voice = Some(default_edge_voice(language).into());
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
        Ok(())
    }
}
