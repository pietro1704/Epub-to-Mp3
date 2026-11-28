use super::{
    cached_chapter_text, chapter_audio_is_complete, chapter_audio_is_reusable,
    chapter_audio_receipt_path, chapter_audio_request_key, ensure_chapter_audio_with_control,
    recover_chapter_audio_for_generation, sanitize, ChapterAudioReceipt, ChapterCompletionEvent,
    ConversionRequest, ConversionWorker, ProgressEvent, WorkerError,
};
use crate::{
    audio::{self, ChapterMetadata},
    cache, epub,
};
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
    /// Earlier jobs whose finished chapters may be reused.
    pub(super) recovery_jobs: &'a [String],
    pub(super) detected_language: Option<&'a str>,
    pub(super) language_profile: &'a crate::language::profile::BookLanguageProfile,
    pub(super) total: usize,
    pub(super) results: &'a Mutex<Vec<(usize, PathBuf, String, ChapterMetadata)>>,
    pub(super) completed: &'a AtomicUsize,
    pub(super) preferences: &'a crate::tts_preferences::TtsPreferences,
}

impl ConversionWorker {
    pub(super) fn process_chapter(
        &self,
        context: &ChapterExecutionContext<'_>,
        position: usize,
        source_index: usize,
        chapter: &epub::Chapter,
    ) -> Result<(), WorkerError> {
        let language_profile = context.language_profile;
        // A monolingual book is read entirely in its main language: every passage is routed to it
        // (explicit passage corrections still win), so a quotation never asks for another voice.
        let routed_request;
        let request = match language_profile.monolingual_language() {
            Some(primary) if context.request.language.is_none() => {
                routed_request = ConversionRequest {
                    language: Some(primary.to_owned()),
                    ..context.request.clone()
                };
                &routed_request
            }
            _ => context.request,
        };
        let book = context.book;
        let cache_dir = context.cache_dir;
        let output_dir = context.output_dir;
        let book_key = context.book_key;
        let detected_language = context.detected_language;
        let total = context.total;
        let results = context.results;
        let completed = context.completed;
        let preferences = context.preferences;
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
        let heading_ends = chapter
            .heading_ends
            .iter()
            .copied()
            .filter(|end| *end > text_offset)
            .map(|end| end - text_offset)
            .collect::<Vec<_>>();
        let stem = format!("{:04}-{}", position + 1, sanitize(&chapter.name));
        let mp3 = output_dir.join(format!("{stem}.mp3"));
        let chapter_analysis = crate::language::analyze_book(
            std::iter::once(chapter.text.as_str()),
            book.language.as_deref(),
            &|| self.cancel.is_cancelled(),
        )
        .map_err(|_| WorkerError::Cancelled)?;
        let language = detected_language.or(chapter_analysis.confirmed.as_deref());
        let language = request.language.as_deref().or(language);
        // A bilingual or multilingual book is read with the first of its languages that the selected
        // voice speaks, so a missing second-language model never stops the playback (a passage in
        // a language without a voice is read with this main voice).
        let language = match language {
            Some(current)
                if request.language.is_none()
                    && language_profile.class
                        != crate::language::profile::BookLanguageClass::Monolingual
                    && !crate::language::selection_supports_language(
                        &preferences.primary,
                        current,
                    ) =>
            {
                language_profile
                    .languages
                    .iter()
                    .map(|share| share.language.as_str())
                    .find(|candidate| {
                        crate::language::selection_supports_language(
                            &preferences.primary,
                            candidate,
                        )
                    })
                    .or(Some(current))
            }
            other => other,
        };
        let resolved = preferences.resolve_automatic_piper(language, |selection| {
            let (model, config) = self.selection_model_paths(request, selection);
            model.is_file() && config.is_file()
        });
        let preferences = resolved.as_ref().unwrap_or(preferences);
        // Footnote narration: a spoken layer (notes read at their references) derived from the
        // source text; chapters without notes narrate the source text unchanged.
        // Coverage and progress stay on the source text axis, whatever is spoken.
        let source_text_chars = text.chars().count();
        let spoken_chapter = crate::epub::footnote_narration::SpokenChapter::derive(
            text,
            text_offset,
            &paragraph_ends,
            &heading_ends,
            &chapter.note_marks,
            preferences.footnote_narration,
            language,
        );
        let (text, paragraph_ends, heading_ends) = match &spoken_chapter {
            Some(spoken) => (
                spoken.text.as_str(),
                spoken.paragraph_ends.clone(),
                spoken.heading_ends.clone(),
            ),
            None => (text, paragraph_ends, heading_ends),
        };
        let note_edges: &[usize] = spoken_chapter
            .as_ref()
            .map_or(&[], |spoken| &spoken.note_edges);
        let engine = &preferences.primary.engine;
        let base_request_key = chapter_audio_request_key(
            &book_key,
            &chapter.index,
            &text,
            if self.platform_tts.is_some() && engine == "edge" {
                // Keep the existing typed request fingerprint stable across this cleanup.
                "edge+system-v2"
            } else {
                engine
            },
            // The typed selection joins the identity in `typed_cache_request_key`;
            // this field keeps the request's own voice so existing receipts match.
            request.voice.as_deref(),
            language,
        )?;
        // Detection policy and explicit passage corrections participate in cache
        // identity, so old-language audio cannot survive a corrected request.
        let base_request_key = if request.language.is_some() && self.language_overrides.is_empty() {
            base_request_key
        } else {
            cache::sha256_bytes(
                serde_json::to_vec(&(
                    "book-language-routing-v1",
                    &base_request_key,
                    &chapter_analysis,
                    &self.language_overrides,
                ))
                .expect("language request identity")
                .as_slice(),
            )
        };
        // The profile (and the detector) route the narration, so they are part of its identity.
        let base_request_key = cache::sha256_bytes(
            serde_json::to_vec(&(
                "book-language-profile-v1",
                crate::language::profile::DETECTOR,
                &base_request_key,
                language_profile.class,
                language_profile
                    .languages
                    .iter()
                    .map(|share| share.language.as_str())
                    .collect::<Vec<_>>(),
            ))
            .expect("language profile identity")
            .as_slice(),
        );
        let base_request_key = super::heading_pauses::request_key(
            &base_request_key,
            &super::heading_pauses::Structure::new(text, &heading_ends, &paragraph_ends)
                .with_note_edges(note_edges),
        );
        let request_key =
            self.typed_cache_request_key(request, preferences, language, &base_request_key)?;
        let reject_opaque_native = true;
        if !self.execution_options.force_reprocess {
            for predecessor in context.recovery_jobs {
                if chapter_audio_is_reusable(&mp3, &request_key, reject_opaque_native) {
                    break;
                }
                recover_chapter_audio_for_generation(
                    &self.config.paths.output_dir,
                    predecessor,
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
                crate::diagnostic!("synthesizing chapter {}/{}", position + 1, total);
                let synthesis = self.synthesize_preferences_at_generation(
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
                    &heading_ends,
                    spoken_chapter.as_ref(),
                );
                if stale_window_cancelled.load(Ordering::Acquire) {
                    return Err(WorkerError::PlaybackWindowChanged);
                }
                synthesis?;
                audio::finalize_mp3(pending)?;
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
                let fallback_used = self
                    .fallback_chapters
                    .lock()
                    .expect("fallback chapter lock")
                    .contains(&source_index);
                // Include actual provider roles in the initial completion receipt,
                // before either durable chapter artifact is published.
                cache::atomic_write_json(
                    pending.with_extension("tts-usage.json"),
                    &(used_selections, fallback_used),
                )?;
                let provider = actual_providers
                    .lock()
                    .expect("provider lock")
                    .iter()
                    .map(|selection| selection.engine.clone())
                    .collect::<Vec<_>>()
                    .join("+");
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
                    .map_err(WorkerError::Control)?;
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
                    .map_err(WorkerError::Control)?;
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
                text_chars: source_text_chars,
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
                text_chars: source_text_chars,
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
