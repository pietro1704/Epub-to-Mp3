use super::{
    cached_chapter_text, chapter_audio_is_complete, chapter_audio_is_reusable,
    chapter_audio_receipt_path, chapter_audio_request_key, ensure_chapter_audio_with_control,
    recover_chapter_audio_for_generation, sanitize, select_engine, ChapterAudioReceipt,
    ChapterCompletionEvent, ConversionRequest, ConversionWorker, ProgressEvent, WorkerError,
};
use crate::{audio::ChapterMetadata, cache, epub};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex,
    },
};

pub(super) struct ChapterExecutionContext<'a> {
    pub(super) request: &'a ConversionRequest,
    pub(super) book: &'a epub::Book,
    pub(super) cache_dir: &'a Path,
    pub(super) output_dir: &'a Path,
    pub(super) book_key: &'a str,
    pub(super) detected_language: Option<&'a str>,
    pub(super) total: usize,
    pub(super) results: &'a Mutex<Vec<(usize, PathBuf, String, ChapterMetadata)>>,
    pub(super) completed: &'a AtomicUsize,
    pub(super) system_notice_emitted: &'a std::sync::atomic::AtomicBool,
}

impl ConversionWorker {
    pub(super) fn process_chapter(
        &self,
        context: &ChapterExecutionContext<'_>,
        position: usize,
        source_index: usize,
        chapter: &epub::Chapter,
    ) -> Result<(), WorkerError> {
        let request = context.request;
        let book = context.book;
        let cache_dir = context.cache_dir;
        let output_dir = context.output_dir;
        let book_key = context.book_key;
        let detected_language = context.detected_language;
        let total = context.total;
        let results = context.results;
        let completed = context.completed;
        let system_notice_emitted = context.system_notice_emitted;
        if self.cancel.is_cancelled() || self.jobs.is_cancellation_requested(&request.job_id)? {
            return Err(WorkerError::Cancelled);
        }
        let text_path = cache_dir.join(format!("{}.json", chapter.index.replace('.', "_")));
        let text = if self.execution_options.clear_cache {
            cache::refresh_chapter_text(
                &self.config.paths.cache_dir,
                &book_key,
                &format!("{}.json", chapter.index.replace('.', "_")),
                &chapter.text,
            )?
        } else {
            cached_chapter_text(&text_path, &chapter.text)?
        };
        let listening = self
            .control
            .as_ref()
            .and_then(|control| control.listening_plan());
        if listening.is_some() && request.tts_preferences.is_none() {
            return Err(WorkerError::Unsupported(
                "Versioned listening requires captured TTS preferences".into(),
            ));
        }
        let generation = listening.as_ref().map(|plan| plan.generation);
        let (text, text_offset) = match &listening {
            Some(plan) => plan
                .remaining_text(source_index, &text)
                .map_err(|error| WorkerError::Unsupported(error.to_string()))?,
            None => (text.as_str(), 0),
        };
        let paragraph_ends = chapter
            .paragraph_ends
            .iter()
            .copied()
            .filter(|end| *end > text_offset)
            .map(|end| end - text_offset)
            .collect::<Vec<_>>();
        let stem = format!("{:04}-{}", position + 1, sanitize(&chapter.name));
        let mp3 = output_dir.join(format!("{stem}.mp3"));
        let language = detected_language;
        let engine = request
            .tts_preferences
            .as_ref()
            .map(|p| p.primary.engine.clone())
            .unwrap_or_else(|| select_engine(request.engine.as_deref(), &self.config));
        let language = request.language.as_deref().or(language);
        let explicit_paths = request.piper_model.is_some() || request.piper_config.is_some();
        let prepared_identity = if request.tts_preferences.is_none() && !explicit_paths {
            self.piper_model
                .as_ref()
                .map(|model| model.cache_identity())
        } else {
            None
        };
        let explicit_identity =
            if engine == "piper" && request.tts_preferences.is_none() && explicit_paths {
                let model = request.piper_model.clone().unwrap_or_else(|| {
                    self.config
                        .paths
                        .piper_models_dir
                        .join("pt_BR-faber-medium.onnx")
                });
                let config = request
                    .piper_config
                    .clone()
                    .unwrap_or_else(|| model.with_extension("onnx.json"));
                // Legacy recovery must obey today's policy before cached bytes
                // can bypass runtime preparation or synthesis entirely.
                crate::piper::validate_model_file_quality(&model, &config)
                    .map_err(|error| WorkerError::Piper(error.to_string()))?;
                Some(format!(
                    "piper:{model:?}:{config:?}:{}:{}",
                    cache::sha256_file(&model)?,
                    cache::sha256_file(&config)?
                ))
            } else {
                None
            };
        let base_request_key = chapter_audio_request_key(
            &book_key,
            &chapter.index,
            &text,
            if let Some(identity) = explicit_identity
                .as_deref()
                .or(prepared_identity.as_deref())
                .filter(|_| engine == "piper")
            {
                identity
            } else if self.platform_tts.is_some() && engine == "edge" {
                "edge+system-v2"
            } else {
                &engine
            },
            request.voice.as_deref(),
            language,
        )?;
        let request_key = if let Some(preferences) = &request.tts_preferences {
            self.typed_cache_request_key(request, preferences, language, &base_request_key)?
        } else {
            base_request_key
        };
        let reject_opaque_native = request.tts_preferences.is_some();
        // Recover only after computing the effective provider/model identity.
        // Legacy unprepared Piper requests still lack a content fingerprint.
        let recovery_has_model_identity = engine != "piper"
            || request.tts_preferences.is_some()
            || explicit_identity.is_some()
            || prepared_identity.is_some();
        if !self.execution_options.force_reprocess
            && recovery_has_model_identity
            && !chapter_audio_is_reusable(&mp3, &request_key, reject_opaque_native)
        {
            if let Some(predecessor) = self
                .control
                .as_ref()
                .and_then(|control| control.recover_job())
            {
                recover_chapter_audio_for_generation(
                    &self.config.paths.output_dir,
                    &predecessor,
                    &mp3,
                    &request_key,
                    reject_opaque_native,
                    &|| {
                        if self.cancel.is_cancelled()
                            || self.jobs.is_cancellation_requested(&request.job_id)?
                        {
                            return Err(WorkerError::Cancelled);
                        }
                        Ok(())
                    },
                    self.control.as_ref(),
                    generation,
                    Some(source_index),
                )?;
            }
        }
        let cached = !self.execution_options.force_reprocess
            && chapter_audio_is_reusable(&mp3, &request_key, reject_opaque_native);

        if cached {
            if let Ok(receipt) =
                cache::read_json::<ChapterAudioReceipt>(chapter_audio_receipt_path(&mp3))
            {
                if receipt
                    .provider
                    .as_deref()
                    .is_some_and(|provider| provider.contains("system"))
                {
                    self.emit(ProgressEvent {
                        render_progress: None,
                        model_id: None,
                        voice: None,
                        fallback_used: receipt.fallback_used,
                        job_id: request.job_id.clone(),
                        state: "running".into(),
                        chapter_index: Some(source_index),
                        chapters_total: total,
                        chapters_completed: completed.load(Ordering::Acquire),
                        percent: 0.0,
                        engine: Some("system".into()),
                        message: "Playing cached audio with occasional system-voice segments..."
                            .into(),
                    });
                }
            }
        }
        let stale_window_cancelled = std::sync::atomic::AtomicBool::new(false);
        let actual_providers = Mutex::new(Vec::<crate::tts_preferences::TtsSelection>::new());
        let audio_result = ensure_chapter_audio_with_control(
            &mp3,
            &request_key,
            self.execution_options.force_reprocess
                || (reject_opaque_native
                    && !cached
                    && chapter_audio_is_complete(&mp3, &request_key)),
            self.control.as_ref(),
            generation,
            Some(source_index),
            |pending| {
                eprintln!("synthesizing chapter {}/{}", position + 1, total);
                let synthesis = if let Some(preferences) = &request.tts_preferences {
                    self.synthesize_preferences_at_generation(
                        request,
                        preferences,
                        &text,
                        pending,
                        source_index,
                        language,
                        &stale_window_cancelled,
                        &actual_providers,
                        total,
                        generation,
                        &paragraph_ends,
                    )
                } else if self.platform_tts.is_some()
                    && matches!(engine.as_str(), "edge" | "system")
                {
                    self.synthesize_platform_policy(
                        &engine,
                        &text,
                        pending,
                        source_index,
                        request.voice.as_deref(),
                        language,
                        &stale_window_cancelled,
                        &system_notice_emitted,
                        &request.job_id,
                        total,
                        completed.load(Ordering::Acquire),
                    )
                } else {
                    self.synthesize_with_timeout(
                        &engine,
                        &text,
                        pending,
                        source_index,
                        request.voice.as_deref(),
                        language,
                        request.piper_model.as_deref(),
                        request.piper_config.as_deref(),
                        &stale_window_cancelled,
                    )
                };
                if stale_window_cancelled.load(Ordering::Acquire) {
                    return Err(WorkerError::PlaybackWindowChanged);
                }
                synthesis?;
                if self
                    .control
                    .as_ref()
                    .is_some_and(|control| !control.generation_is_current(generation))
                {
                    return Err(WorkerError::PlaybackWindowChanged);
                }
                if self.cancel.is_cancelled()
                    || self.jobs.is_cancellation_requested(&request.job_id)?
                {
                    return Err(WorkerError::Cancelled);
                }
                let used_selections = actual_providers.lock().expect("provider lock").clone();
                let fallback_used = if request.tts_preferences.is_some() {
                    self.fallback_chapters
                        .lock()
                        .expect("fallback chapter lock")
                        .contains(&source_index)
                } else {
                    engine == "edge"
                        && fs::read_to_string(pending.with_extension("provider"))
                            .ok()
                            .is_some_and(|provider| provider.contains("system"))
                };
                // Include actual provider roles in the initial completion receipt,
                // before either durable chapter artifact is published.
                cache::atomic_write_json(
                    pending.with_extension("tts-usage.json"),
                    &(used_selections, fallback_used),
                )?;
                let provider = if request.tts_preferences.is_some() {
                    actual_providers
                        .lock()
                        .expect("provider lock")
                        .iter()
                        .map(|selection| selection.engine.clone())
                        .collect::<Vec<_>>()
                        .join("+")
                } else {
                    fs::read_to_string(pending.with_extension("provider"))
                        .unwrap_or_else(|_| engine.clone())
                };
                fs::write(pending.with_extension("provider"), provider)?;
                Ok(())
            },
        );
        match audio_result {
            Err(WorkerError::PlaybackWindowChanged) => {
                self.control
                    .as_ref()
                    .expect("playback-window cancellation requires conversion control")
                    .requeue(source_index)
                    .map_err(|error| WorkerError::Piper(error.to_string()))?;
                return Ok(());
            }
            Err(error) => return Err(error),
            Ok(()) => {}
        }
        if let Some(control) = &self.control {
            if !control.chapter_is_in_playback_window(source_index)
                || !control.generation_is_current(generation)
            {
                control
                    .requeue(source_index)
                    .map_err(|error| WorkerError::Piper(error.to_string()))?;
                return Ok(());
            }
        }
        if self.cancel.is_cancelled() || self.jobs.is_cancellation_requested(&request.job_id)? {
            return Err(WorkerError::Cancelled);
        }
        let name = mp3.file_name().unwrap().to_string_lossy().to_string();
        self.render_progress
            .lock()
            .expect("render progress lock")
            .complete(source_index);
        let mut result_entries = results.lock().unwrap();
        let previous = result_entries
            .iter()
            .position(|(index, _, _, _)| *index == position);
        let chapters_completed = if previous.is_some() {
            completed.load(Ordering::Acquire)
        } else {
            completed.fetch_add(1, Ordering::AcqRel) + 1
        };
        if let Some(sink) = &self.chapter_completed {
            sink(ChapterCompletionEvent {
                job_id: request.job_id.clone(),
                book_title: book.title.clone(),
                book_author: book.author.clone(),
                chapter_index: source_index,
                chapters_total: total,
                chapters_completed,
                chapter_title: chapter.name.clone(),
                filename: name.clone(),
                audio_path: mp3.clone(),
                text_chars: text.chars().count(),
            });
        }
        let result_entry = (
            position,
            mp3,
            name.clone(),
            ChapterMetadata {
                index: position + 1,
                source_index,
                title: chapter.name.clone(),
                filename: name,
                text_chars: text.chars().count(),
                text_offset,
            },
        );
        if let Some(previous) = previous {
            result_entries[previous] = result_entry;
        } else {
            result_entries.push(result_entry);
        }
        Ok(())
    }
}
