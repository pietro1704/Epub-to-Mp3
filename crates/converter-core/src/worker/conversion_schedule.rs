use super::chapter_execution::ChapterExecutionContext;
use super::{
    chapter_audio_receipt_path, chapter_selection_matches, detect_language,
    refresh_chapter_audio_receipt, sanitize, ChapterAudioReceipt, ConversionRequest,
    ConversionWorker, OutputManifest, WorkerError,
};
use crate::{audio, cache, epub};
use rayon::prelude::*;
use std::{
    fs, io,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex,
    },
};

impl ConversionWorker {
    pub(super) fn run_inner(
        &self,
        request: &ConversionRequest,
    ) -> Result<OutputManifest, WorkerError> {
        if !self.pronunciation.rules.is_empty() && request.tts_preferences.is_none() {
            return Err(WorkerError::Unsupported(
                "Pronunciation requires an explicit captured TTS selection".into(),
            ));
        }
        if self
            .control
            .as_ref()
            .is_some_and(|control| control.listening_plan().is_some())
            && request.tts_preferences.is_none()
        {
            return Err(WorkerError::Unsupported(
                "Versioned listening requires captured TTS preferences".into(),
            ));
        }
        if request.tts_preferences.is_none()
            && request
                .engine
                .as_deref()
                .is_some_and(|e| !matches!(e, "auto" | "piper" | "edge" | "system"))
        {
            return Err(WorkerError::Piper("Unsupported conversion engine".into()));
        }
        self.consecutive_edge_failures.store(0, Ordering::Release);
        self.fallback_chapters
            .lock()
            .expect("fallback chapter lock")
            .clear();
        *self.segment_policy.lock().expect("segment policy lock") =
            self.initial_segment_policy.clone();
        if !request.input.is_file() {
            return Err(WorkerError::Io(io::Error::new(
                io::ErrorKind::NotFound,
                request.input.display().to_string(),
            )));
        }
        let ext = request
            .input
            .extension()
            .and_then(|x| x.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if ext != "epub" {
            return Err(WorkerError::Unsupported(ext));
        }
        // Read the immutable source once: parsing the ZIP and hashing it from
        // separate file handles doubled disk I/O for every conversion.
        let source = fs::read(&request.input)?;
        let book_key = cache::sha256_bytes(&source);
        *self.source_identity.lock().expect("source identity lock") = Some(book_key.clone());
        let book = epub::parse_epub(std::io::Cursor::new(&source))?;
        let source_chapters_total = book.chapters.len();
        let cache_dir = self.config.paths.cache_dir.join(&book_key);
        let output_dir = self.config.paths.output_dir.join(&request.job_id);
        fs::create_dir_all(&cache_dir)?;
        fs::create_dir_all(&output_dir)?;
        cache::atomic_write_json(
            self.config
                .paths
                .jobs_dir
                .join("requests")
                .join(format!("{}.json", request.job_id)),
            request,
        )?;
        let chapters: Vec<_> = book
            .chapters
            .iter()
            .enumerate()
            .filter(|(position, chapter)| {
                request
                    .chapter_indices
                    .as_ref()
                    .map(|wanted| {
                        wanted.iter().any(|value| {
                            chapter_selection_matches(value, &chapter.index, *position)
                        })
                    })
                    .unwrap_or(true)
            })
            .map(|(source_index, chapter)| (source_index, chapter))
            .collect();
        let total = chapters.len();
        *self.render_progress.lock().expect("render progress lock") =
            super::render_progress::RenderProgress::new(
                chapters
                    .iter()
                    .map(|(index, chapter)| (*index, chapter.text.chars().count())),
            );
        let source_text_chars: usize = chapters
            .iter()
            .map(|(_, chapter)| chapter.text.chars().count())
            .sum();
        if total == 0 || source_text_chars == 0 {
            return Err(WorkerError::Piper(
                "selected chapters have no readable text".into(),
            ));
        }
        if let Some(control) = &self.control {
            control
                .attach(&chapters.iter().map(|(index, _)| *index).collect::<Vec<_>>())
                .map_err(|error| WorkerError::Piper(error.to_string()))?;
        }
        let detected_language = request
            .language
            .as_deref()
            .or(book.language.as_deref())
            .or_else(|| {
                book.chapters
                    .first()
                    .and_then(|chapter| detect_language(&chapter.text))
            });
        let parallelism = if request.tts_preferences.is_some()
            || (request.no_parallel && !self.execution_options.max_performance)
        {
            1
        } else {
            let configured = std::env::var("RUST_CHAPTER_PARALLELISM")
                .ok()
                .and_then(|value| value.parse().ok())
                .filter(|value| *value > 0)
                .unwrap_or_else(|| {
                    std::thread::available_parallelism()
                        .map(|v| v.get())
                        .unwrap_or(1)
                });
            let cap = std::env::var("RUST_CHAPTER_PARALLELISM_CAP")
                .ok()
                .and_then(|value| value.parse().ok())
                .filter(|value| *value > 0)
                .unwrap_or(8);
            self.execution_options.chapter_parallelism(
                request.no_parallel,
                configured,
                self.config.max_parallel,
                cap,
            )
        };
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(parallelism)
            .build()
            .map_err(|error| WorkerError::Piper(error.to_string()))?;
        let results = Mutex::new(Vec::with_capacity(total));
        let completed = AtomicUsize::new(0);
        let system_notice_emitted = std::sync::atomic::AtomicBool::new(false);
        let chapter_context = ChapterExecutionContext {
            request: request,
            book: &book,
            cache_dir: &cache_dir,
            output_dir: &output_dir,
            book_key: &book_key,
            detected_language: detected_language,
            total: total,
            results: &results,
            completed: &completed,
            system_notice_emitted: &system_notice_emitted,
        };
        let process_chapter = |position, source_index, chapter| {
            self.process_chapter(&chapter_context, position, source_index, chapter)
        };
        if let Some(control) = &self.control {
            while let Some(source_index) = control
                .take()
                .map_err(|error| WorkerError::Piper(error.to_string()))?
            {
                let Some((position, (_, chapter))) = chapters
                    .iter()
                    .enumerate()
                    .find(|(_, (candidate, _))| *candidate == source_index)
                else {
                    continue;
                };
                process_chapter(position, source_index, chapter)?;
            }
        } else {
            pool.install(|| {
                chapters.par_iter().enumerate().try_for_each(
                    |(position, (source_index, chapter))| {
                        process_chapter(position, *source_index, chapter)
                    },
                )
            })?;
        }
        if self.cancel.is_cancelled() || self.jobs.is_cancellation_requested(&request.job_id)? {
            return Err(WorkerError::Cancelled);
        }
        let mut results = results.into_inner().unwrap();
        results.sort_by_key(|item| item.0);
        let files: Vec<_> = results
            .iter()
            .map(|(_, path, name, _)| (path.clone(), name.clone()))
            .collect();
        let manifest: Vec<_> = results
            .iter()
            .map(|(_, _, _, metadata)| metadata.clone())
            .collect();
        let output_text_chars: usize = manifest
            .iter()
            .map(|chapter| chapter.text_chars + chapter.text_offset)
            .sum();
        if output_text_chars != source_text_chars {
            return Err(WorkerError::Piper(format!(
                "text coverage mismatch: source={source_text_chars}, output={output_text_chars}"
            )));
        }
        let cover = if cfg!(target_os = "android") {
            None
        } else {
            book.cover
                .as_ref()
                .map(|cover| {
                    let extension = match book.cover_mime.as_deref() {
                        Some("image/png") => "png",
                        Some("image/webp") => "webp",
                        _ => "jpg",
                    };
                    let name = format!("cover.{extension}");
                    let path = output_dir.join(&name);
                    std::fs::write(&path, cover).ok()?;
                    Some(name)
                })
                .flatten()
        };
        if let Some(cover_name) = &cover {
            let cover_path = output_dir.join(cover_name);
            for (_, path, _, _) in &results {
                audio::embed_cover(path, &cover_path)?;
                refresh_chapter_audio_receipt(path)?;
            }
        }
        let archive = output_dir.join(format!("{}.zip", sanitize(&book.title)));
        let archive_files = files
            .iter()
            .cloned()
            .chain(
                cover
                    .as_ref()
                    .map(|name| (output_dir.join(name), name.clone())),
            )
            .collect::<Vec<_>>();
        audio::create_archive(&archive, &archive_files)?;
        let output_name = archive.file_name().unwrap().to_string_lossy().to_string();
        let mut used_selections = Vec::new();
        let mut synthesis_sessions = Vec::new();
        let mut fallback_used = false;
        for (path, _) in &files {
            if let Ok(receipt) =
                cache::read_json::<ChapterAudioReceipt>(chapter_audio_receipt_path(path))
            {
                fallback_used |= receipt.fallback_used;
                for identity in receipt.synthesis_sessions {
                    if !synthesis_sessions.contains(&identity) {
                        synthesis_sessions.push(identity);
                    }
                }
                for selection in receipt.used_selections {
                    if !used_selections.contains(&selection) {
                        used_selections.push(selection);
                    }
                }
            }
        }
        let policy = self
            .segment_policy
            .lock()
            .expect("segment policy lock")
            .clone();
        let result = OutputManifest {
            source_chapters_total: Some(source_chapters_total),
            tts_preferences: request.tts_preferences.clone(),
            used_selections,
            synthesis_sessions,
            fallback_used,
            // Typed jobs must publish zero explicitly so persisted clients clear
            // an earlier failure counter. Only historical metadata is absent.
            tts_policy_state: (request.tts_preferences.is_some() || !policy.is_initial())
                .then_some(policy),

            job_id: request.job_id.clone(),
            title: book.title,
            author: book.author,
            chapters: manifest,
            archive: output_name,
            cover,
        };
        cache::atomic_write_json(output_dir.join("manifest.json"), &result)?;
        Ok(result)
    }
}
