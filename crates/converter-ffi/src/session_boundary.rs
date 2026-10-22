use super::*;

/// Opens and parses an EPUB at a NUL-terminated UTF-8 path.
///
/// On failure, returns null and stores a thread-local error retrievable with
/// `converter_last_error`.
#[no_mangle]
pub unsafe extern "C" fn converter_session_open(path: *const c_char) -> *mut ConverterSession {
    clear_last_error();
    let path = match c_string(path, "path") {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    let config = AppConfig::from_paths(resolve_paths_from(
        HashMap::<String, String>::new(),
        std::env::temp_dir().join("converter-ffi"),
    ));
    match EmbeddedConversionSession::open(Path::new(&path), Default::default(), config) {
        Ok(session) => Box::into_raw(Box::new(ConverterSession {
            session,
            platform_tts: None,
        })),
        Err(error) => fail(error.to_string()),
    }
}

/// Returns metadata as an owned UTF-8 JSON string, or null for an invalid handle.
#[no_mangle]
pub unsafe extern "C" fn converter_session_metadata_json(
    handle: *const ConverterSession,
) -> *mut c_char {
    clear_last_error();
    let session = match handle.as_ref() {
        Some(handle) => handle,
        None => return fail("invalid null session handle".to_owned()),
    };
    let metadata = metadata_json(
        session.session.metadata(),
        session.session.structure_verification(),
    );
    match CString::new(metadata) {
        Ok(value) => value.into_raw(),
        Err(error) => fail(format!("metadata contains an interior NUL byte: {error}")),
    }
}

/// Converts the EPUB and returns the generated manifest as an owned JSON
/// string. Audio files are written by the Rust worker under its configured
/// persistent output directory.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_json(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
) -> *mut c_char {
    clear_last_error();
    let _ = rustls::crypto::ring::default_provider().install_default();
    let session = match handle.as_ref() {
        Some(handle) => handle,
        None => return fail("invalid null session handle".to_owned()),
    };
    let output_dir = match c_string(output_dir, "output directory") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let mut config = AppConfig::from_paths(resolve_paths_from(
        [("OUTPUT_DIR".to_owned(), output_dir.clone())],
        std::path::PathBuf::from(output_dir.clone()),
    ));
    config.max_parallel = config.max_parallel.min(embedded_chapter_parallelism_cap());
    let output = Path::new(&output_dir);
    if let Err(error) = std::fs::create_dir_all(output) {
        return fail(format!("failed to create output directory: {error}"));
    }
    let job = converter_core::embedded::fresh_embedded_job_id();
    let generated_output_dir = output.join(&job);
    let request = converter_core::worker::ConversionRequest {
        tts_preferences: None,
        models_root: None,
        input: session.session.input_path().to_path_buf(),
        job_id: job,
        engine: Some("edge".to_owned()),
        voice: None,
        language: None,
        piper_model: None,
        piper_config: None,
        chapter_indices: positional_chapter_selection(session, chapter_start, chapter_end),
        no_parallel: chapter_start >= 0,
    };
    let progress_log = generated_output_dir.join("conversion.log");
    let system_voice_used = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let used_system = Arc::clone(&system_voice_used);
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
        let line = progress_log_line(&event, conversion_started, &previous_event);
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&progress_log)
        {
            let _ = file.write_all(line.as_bytes());
        }
    }));
    let worker = if let Some(provider) = session.platform_tts.clone() {
        worker.with_platform_tts(provider)
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
                .map(|chapter| generated_output_dir.join(&chapter.filename));
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
