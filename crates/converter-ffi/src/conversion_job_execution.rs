use super::*;

pub(super) unsafe fn convert_job_json(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
    control: Option<ConversionControl>,
    chunk_callback: ConverterAudioChunkCallback,
    options: EmbeddedConversionOptionsV1,
) -> *mut c_char {
    clear_last_error();
    let _ = rustls::crypto::ring::default_provider().install_default();
    let session = match handle.as_ref() {
        Some(handle) => handle,
        None => return fail("invalid null session handle".to_owned()),
    };
    let output_dir = match c_string(output_dir, "output directory") {
        Ok(value) => Path::new(&value).to_path_buf(),
        Err(error) => return fail(error),
    };
    let job_id = match c_string(job_id, "job ID") {
        Ok(value) if !value.is_empty() => value,
        Ok(_) => return fail("job ID must not be empty".to_owned()),
        Err(error) => return fail(error),
    };
    let Some(output_parent) = output_dir.parent() else {
        return fail("output directory must have a parent".to_owned());
    };
    if output_dir.file_name().and_then(|name| name.to_str()) != Some(job_id.as_str()) {
        return fail("output directory name must match the job ID".to_owned());
    }
    if let Err(error) = std::fs::create_dir_all(&output_dir) {
        return fail(format!("failed to create output directory: {error}"));
    }
    let output_root = output_parent.to_string_lossy().into_owned();
    let mut config = AppConfig::from_paths(resolve_paths_from(
        [("OUTPUT_DIR".to_owned(), output_root.clone())],
        output_parent.to_path_buf(),
    ));
    config.max_parallel = config.max_parallel.min(embedded_chapter_parallelism_cap());
    let mut options = options;
    if let Some(preferences) = &options.tts_preferences {
        if let Err(error) = preferences.validate(options.language.as_deref()) {
            return fail(error);
        }
        options.engine = Some(preferences.primary.engine.clone());
        options.voice = preferences.primary.voice.clone();
        options.model_id = preferences.primary.model_id.clone();
    }
    if options
        .engine
        .as_deref()
        .is_some_and(|engine| !matches!(engine, "piper" | "edge" | "system"))
    {
        return fail("Unsupported conversion engine".to_owned());
    }
    let engine = embedded_engine_from_value(options.engine.as_deref());

    let requires_piper = engine == "piper"
        || options
            .tts_preferences
            .as_ref()
            .and_then(|p| p.secondary.as_ref())
            .is_some_and(|s| s.engine == "piper");
    if options.models_root.is_none()
        && options
            .tts_preferences
            .as_ref()
            .is_some_and(|p| p.continues_native())
    {
        options.models_root = Some(config.paths.piper_models_dir.to_string_lossy().into_owned());
    }
    let (piper_model, piper_config) = if requires_piper {
        if engine != "piper" {
            options.model_id = options
                .tts_preferences
                .as_ref()
                .and_then(|p| p.secondary.as_ref())
                .and_then(|s| s.model_id.clone());
        }
        let (model, config) = match resolve_piper_model_paths(&options) {
            Ok(paths) => paths,
            Err(error) => return fail(error),
        };
        #[cfg(feature = "piper-runtime")]
        if let Some(directory) = options.espeak_data_directory.as_deref() {
            if let Err(error) = piper_runtime::set_espeak_data_directory(Path::new(directory)) {
                if !options
                    .tts_preferences
                    .as_ref()
                    .is_some_and(|p| p.continues_native())
                {
                    return fail(error);
                }
            }
        }
        #[cfg(feature = "piper-runtime")]
        piper_runtime_register_embedded();
        #[cfg(not(feature = "piper-runtime"))]
        piper_runtime_register_unavailable();
        (Some(model), Some(config))
    } else {
        (None, None)
    };
    let queued_audio = options.audio_chunks.clone();
    let request = converter_core::worker::ConversionRequest {
        tts_preferences: options.tts_preferences,
        models_root: options.models_root.map(std::path::PathBuf::from),
        input: session.session.input_path().to_path_buf(),
        job_id: job_id.clone(),
        engine: Some(engine),
        voice: options.voice,
        language: options.language,
        piper_model,
        piper_config,
        chapter_indices: positional_chapter_selection(session, chapter_start, chapter_end),
        no_parallel: chapter_start >= 0 || control.is_some(),
    };
    let progress_log = output_dir.join("conversion.log");
    let system_voice_used = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let used_system = Arc::clone(&system_voice_used);
    let context_address = context as usize;
    let progress_callback = progress_callback;
    let conversion_started = std::time::Instant::now();
    let previous_event = std::sync::Mutex::new(conversion_started);
    let worker = match converter_core::worker::ConversionWorker::new(config) {
        Ok(worker) => worker,
        Err(error) => return fail(error.to_string()),
    }
    .with_progress(Arc::new(move |event| {
        if event.engine.as_deref() == Some("system") {
            used_system.store(true, std::sync::atomic::Ordering::Release);
        }
        use std::io::Write;
        let line = progress_log_line(&event, conversion_started, &previous_event);
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&progress_log)
        {
            let _ = file.write_all(line.as_bytes());
        }
        if let Some(callback) = progress_callback {
            if let Ok(json) = serde_json::to_string(&event) {
                if let Ok(json) = CString::new(json) {
                    unsafe { callback(json.as_ptr(), context_address as *mut c_void) };
                }
            }
        }
    }))
    .with_chapter_completed(Arc::new(move |event| {
        let Some(callback) = callback else { return };
        let Ok(json) = serde_json::to_string(&event) else {
            return;
        };
        let Ok(json) = CString::new(json) else { return };
        unsafe { callback(json.as_ptr(), context_address as *mut c_void) };
    }));
    let worker = worker.with_tts_policy_state(options.tts_policy_state.clone().unwrap_or_default());
    let chunk_context_address = context as usize;
    let worker = if let Some(provider) = session.platform_tts.clone() {
        worker.with_platform_tts(provider)
    } else {
        worker
    };
    let queue_control = control.clone();
    let queue_root = output_dir.join(".streaming").join(format!(
        "run-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let worker = if let Some(queue) =
        queued_audio.filter(|queue| queue.lock().is_ok_and(|queue| queue.enabled))
    {
        worker.with_streaming_chunks(Arc::new(move |chapter_index, chunk_index, audio| {
            if queue_control
                .as_ref()
                .is_some_and(|control| control.cancellation_token().is_cancelled())
            {
                return false;
            }
            let path = queue_root.join(format!("chapter-{chapter_index}-chunk-{chunk_index}.mp3"));
            let publish = || -> Result<(), String> {
                std::fs::create_dir_all(&queue_root).map_err(|error| error.to_string())?;
                // Every chapter/chunk pair is immutable within this conversion.
                use std::io::Write;
                let mut file = std::fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&path)
                    .map_err(|error| error.to_string())?;
                file.write_all(audio).map_err(|error| error.to_string())?;
                file.sync_all().map_err(|error| error.to_string())?;
                Ok(())
            };
            let failure = publish().err();
            let Ok(mut queue) = queue.lock() else {
                return false;
            };
            if let Some(error) = failure {
                queue.error = Some(format!("Streaming audio publication failed: {error}"));
                if let Some(control) = queue_control.as_ref() {
                    control.cancel();
                }
                return false;
            }
            if queue_control
                .as_ref()
                .is_some_and(|control| control.cancellation_token().is_cancelled())
            {
                let _ = std::fs::remove_file(&path);
                return false;
            }
            if queue.events.len() >= AUDIO_CHUNK_QUEUE_CAPACITY {
                queue.error = Some("Streaming audio queue capacity exceeded".into());
                if let Some(control) = queue_control.as_ref() {
                    control.cancel();
                }
                let _ = std::fs::remove_file(&path);
                return false;
            }
            queue.events.push_back(
                json!({"chapterIndex":chapter_index,"chunkIndex":chunk_index,"path":path}),
            );
            true
        }))
    } else if let Some(chunk_callback) = chunk_callback {
        worker.with_streaming_chunks(Arc::new(move |chapter_index, chunk_index, audio| unsafe {
            chunk_callback(
                chapter_index,
                chunk_index,
                audio.as_ptr(),
                audio.len(),
                chunk_context_address as *mut c_void,
            )
        }))
    } else {
        worker
    };
    let worker = if let Some(control) = control {
        worker.with_control(control)
    } else {
        worker
    };
    let conversion_thread = match std::thread::Builder::new()
        .name("converter-ffi-conversion".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| worker.run(request)))
        }) {
        Ok(thread) => thread,
        Err(error) => return fail(format!("failed to start conversion thread: {error}")),
    };
    let result = conversion_thread
        .join()
        .unwrap_or_else(|payload| Err(payload));
    match result {
        Err(payload) => {
            let message = payload
                .downcast_ref::<&str>()
                .copied()
                .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
                .unwrap_or("unknown panic payload");
            fail(format!(
                "Rust converter panicked during embedded conversion: {message}"
            ))
        }
        Ok(Err(error)) => fail(error.to_string()),
        Ok(Ok(manifest)) => {
            let audio_path = manifest
                .chapters
                .first()
                .map(|chapter| output_dir.join(&chapter.filename));
            let response = serde_json::json!({
                "audioPath": audio_path.map(|path| path.to_string_lossy().into_owned()),
                "manifest": manifest,
                "systemVoiceUsed": system_voice_used.load(std::sync::atomic::Ordering::Acquire),
            });
            match serde_json::to_string(&response)
                .ok()
                .and_then(|value| CString::new(value).ok())
            {
                Some(value) => value.into_raw(),
                None => fail("failed to serialize conversion manifest".to_owned()),
            }
        }
    }
}

pub(super) fn positional_chapter_selection(
    session: &ConverterSession,
    chapter_start: i32,
    chapter_end: i32,
) -> Option<Vec<String>> {
    if chapter_start < 0 {
        return None;
    }
    let start = chapter_start as usize;
    let chapter_count = session.session.metadata().chapters.len();
    let end = if chapter_end < 0 {
        chapter_count.saturating_sub(1)
    } else if chapter_end >= chapter_start {
        chapter_end as usize
    } else {
        start
    };
    Some(
        (start..=end)
            .map(|index| format!("position:{index}"))
            .collect(),
    )
}

/// Embedded Apple clients use two concurrent chapter workers by default.
/// Edge TTS is a shared remote service, so this keeps the throughput gain
/// bounded while allowing `RUST_CHAPTER_PARALLELISM=1` for serial benchmarks.
pub(super) fn embedded_chapter_parallelism_cap() -> usize {
    if cfg!(target_os = "macos") || cfg!(target_os = "ios") {
        2
    } else {
        1
    }
}

pub(super) fn progress_log_line(
    event: &converter_core::worker::ProgressEvent,
    started: std::time::Instant,
    previous_event: &std::sync::Mutex<std::time::Instant>,
) -> String {
    let now = std::time::Instant::now();
    let since_previous = previous_event
        .lock()
        .map(|mut previous| {
            let elapsed = now.duration_since(*previous);
            *previous = now;
            elapsed
        })
        .unwrap_or_default();
    let unix_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!(
        "[Rust] unix_ms={unix_ms} elapsed_ms={} since_event_ms={} state={} chapter={:?} completed={} total={} percent={:.1} engine={:?} {}\n",
        started.elapsed().as_millis(),
        since_previous.as_millis(),
        event.state,
        event.chapter_index,
        event.chapters_completed,
        event.chapters_total,
        event.percent,
        event.engine,
        event.message
    )
}
