//! Stable C ABI for opening and converting embedded EPUB sessions.
//!
//! Ownership contract:
//! - `converter_session_open` returns an owned opaque handle, or null on error.
//! - `converter_session_metadata_json` returns an owned UTF-8 string, or null on error.
//! - `converter_session_free` and `converter_string_free` accept null and are no-ops.
//! - `converter_last_error` returns an owned UTF-8 error string, or null when no error exists.
//! - Every returned string must be released with `converter_string_free`.

#[cfg(feature = "piper-runtime")]
extern crate piper_runtime;

use converter_core::piper;
use converter_core::{
    config::AppConfig,
    conversion_control::ConversionControl,
    embedded::{EmbeddedBookMetadata, EmbeddedConversionSession},
    paths::resolve_paths_from,
};

use serde::Deserialize;
use serde_json::json;
use std::{
    collections::HashMap,
    ffi::{c_char, c_void, CStr, CString},
    path::Path,
    ptr,
    sync::Arc,
};

/// Opaque session handle owned by the caller.
#[repr(C)]
pub struct ConverterSession {
    session: EmbeddedConversionSession,
    platform_tts: Option<Arc<dyn converter_core::platform_tts::PlatformTts>>,
}

/// The cancellation context is borrowed only for one synchronous speech call.
pub type ConverterPlatformCancelled = unsafe extern "C" fn(*const c_void) -> bool;
pub type ConverterPlatformTtsCallback = Option<
    unsafe extern "C" fn(
        *const c_char,
        *const c_char,
        *const c_char,
        ConverterPlatformCancelled,
        *const c_void,
        *mut c_char,
        u32,
        *mut c_void,
    ) -> bool,
>;

struct PlatformCancellation<'a> {
    cancelled: &'a (dyn Fn() -> bool + Sync),
}

unsafe extern "C" fn platform_cancelled(context: *const c_void) -> bool {
    if context.is_null() {
        return true;
    }
    let cancellation = &*context.cast::<PlatformCancellation<'_>>();
    (cancellation.cancelled)()
}

struct CPlatformTts {
    callback: unsafe extern "C" fn(
        *const c_char,
        *const c_char,
        *const c_char,
        ConverterPlatformCancelled,
        *const c_void,
        *mut c_char,
        u32,
        *mut c_void,
    ) -> bool,
    context: usize,
}

impl converter_core::platform_tts::PlatformTts for CPlatformTts {
    fn synthesize_wav(
        &self,
        text: &str,
        language: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), String> {
        let text = CString::new(text).map_err(|_| "Speech text contains NUL")?;
        let language = CString::new(language).map_err(|_| "Speech language contains NUL")?;
        let output = CString::new(output.to_string_lossy().as_bytes())
            .map_err(|_| "Speech output path contains NUL")?;
        let cancellation = PlatformCancellation { cancelled };
        let mut error = [0 as c_char; 1024];
        let success = unsafe {
            (self.callback)(
                text.as_ptr(),
                language.as_ptr(),
                output.as_ptr(),
                platform_cancelled,
                (&cancellation as *const PlatformCancellation<'_>).cast(),
                error.as_mut_ptr(),
                error.len() as u32,
                self.context as *mut c_void,
            )
        };
        if success {
            return Ok(());
        }
        error[1023] = 0;
        let message = unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy();
        Err(if message.is_empty() {
            "The installed offline system voice could not synthesize speech".to_owned()
        } else {
            message.into_owned()
        })
    }
}

/// Installs a session-scoped system speech adapter. Configure only while no
/// conversion is active. `context` must stay alive through all conversions and
/// the caller must not retain cancellation pointers after its callback returns.
/// Passing no callback removes the adapter and restores the original policy.
#[no_mangle]
pub unsafe extern "C" fn converter_session_set_platform_tts_v1(
    handle: *mut ConverterSession,
    callback: ConverterPlatformTtsCallback,
    context: *mut c_void,
) -> bool {
    clear_last_error();
    let Some(session) = handle.as_mut() else {
        return fail("invalid null session handle".to_owned());
    };
    session.platform_tts = callback.map(|callback| {
        Arc::new(CPlatformTts {
            callback,
            context: context as usize,
        }) as Arc<dyn converter_core::platform_tts::PlatformTts>
    });
    true
}

/// Registers the owned installed desktop backend; no synchronous Dart callback.
/// Configure only while no conversion is active. No package is installed.
#[no_mangle]
pub unsafe extern "C" fn converter_session_set_desktop_platform_tts_v1(
    handle: *mut ConverterSession,
) -> bool {
    clear_last_error();
    let Some(session) = handle.as_mut() else {
        return fail("invalid null session handle".into());
    };
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    {
        session.platform_tts = Some(Arc::new(
            converter_core::desktop_tts::DesktopPlatformTts::default(),
        ));
        true
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        let _ = session;
        fail("This platform requires its app-provided speech adapter".into())
    }
}

/// A thread-safe conversion control owned independently of the book session.
/// Conversion clones the shared state before starting its worker. The caller
/// must synchronize handle operations with free; the worker never keeps this pointer.
#[repr(C)]
pub struct ConverterJobControl {
    control: ConversionControl,
    audio_chunks: Arc<std::sync::Mutex<AudioChunkQueue>>,
}

#[derive(Default)]
struct AudioChunkQueue {
    enabled: bool,
    events: std::collections::VecDeque<serde_json::Value>,
    error: Option<String>,
}
const AUDIO_CHUNK_QUEUE_CAPACITY: usize = 64;

#[derive(Deserialize, Default)]
#[serde(default)]
struct EmbeddedConversionOptionsV1 {
    #[serde(skip)]
    audio_chunks: Option<Arc<std::sync::Mutex<AudioChunkQueue>>>,
    tts_policy_state: Option<converter_core::tts_preferences::SegmentPolicy>,
    tts_preferences: Option<converter_core::tts_preferences::TtsPreferences>,
    engine: Option<String>,
    voice: Option<String>,
    language: Option<String>,
    models_root: Option<String>,
    model_id: Option<String>,
    model_path: Option<String>,
    model_config_path: Option<String>,
    espeak_data_directory: Option<String>,
}

#[no_mangle]
pub unsafe extern "C" fn converter_conversion_options_validate_json_v1(
    options_json: *const c_char,
) -> bool {
    clear_last_error();
    let json = match c_string(options_json, "conversion options") {
        Ok(json) => json,
        Err(error) => return fail(error),
    };
    let options = match serde_json::from_str::<EmbeddedConversionOptionsV1>(&json) {
        Ok(options) => options,
        Err(error) => return fail(format!("invalid conversion options: {error}")),
    };
    let mut options = options;
    if let Some(preferences) = &options.tts_preferences {
        if let Err(error) = preferences.validate(options.language.as_deref()) {
            return fail(error);
        }
        options.engine = Some(preferences.primary.engine.clone());
        options.voice = preferences.primary.voice.clone();
        options.model_id = preferences.primary.model_id.clone();
    }
    let engine = options
        .engine
        .as_deref()
        .unwrap_or("edge")
        .to_ascii_lowercase();
    if !matches!(engine.as_str(), "edge" | "piper" | "system") {
        return fail(format!("unsupported conversion engine: {engine}"));
    }
    if options
        .language
        .as_deref()
        .is_some_and(|value| value.chars().any(char::is_control))
    {
        return fail("language contains control characters".to_owned());
    }
    if engine == "piper" {
        if (options.models_root.is_none()
            && !options
                .tts_preferences
                .as_ref()
                .is_some_and(|p| p.continues_native()))
            || options.model_id.is_none()
        {
            return fail("Piper requires an explicitly installed local model.".to_owned());
        }
        if let Err(error) = resolve_piper_model_paths(&options) {
            return fail(error);
        }
    } else if options.model_id.is_some()
        || options.model_path.is_some()
        || options.model_config_path.is_some()
    {
        return fail("Piper model configuration cannot be used with Edge.".to_owned());
    }
    true
}

#[no_mangle]
pub extern "C" fn converter_job_control_create() -> *mut ConverterJobControl {
    clear_last_error();
    Box::into_raw(Box::new(ConverterJobControl {
        control: ConversionControl::new(),
        audio_chunks: Default::default(),
    }))
}

/// Enable bounded file-backed audio events before starting conversion. Keep the
/// handle alive until the worker has finished and all queued events are drained.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_enable_audio_chunks(
    control: *const ConverterJobControl,
) -> bool {
    let Some(control) = control.as_ref() else {
        return false;
    };
    let Ok(mut queue) = control.audio_chunks.lock() else {
        return false;
    };
    if queue.enabled {
        return false;
    }
    queue.enabled = true;
    true
}

/// Nonblocking poll. Returns an owned JSON string, or null when no event is ready.
/// Payload is {chapterIndex,chunkIndex,path}; an overflow returns {error} and
/// cancels conversion. Release each string with converter_string_free.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_take_audio_chunk_json(
    control: *const ConverterJobControl,
) -> *mut c_char {
    let Some(control) = control.as_ref() else {
        return ptr::null_mut();
    };
    let Ok(mut queue) = control.audio_chunks.try_lock() else {
        return ptr::null_mut();
    };
    let event = queue
        .error
        .take()
        .map(|error| json!({"error":error}))
        .or_else(|| queue.events.pop_front());
    event
        .and_then(|event| CString::new(event.to_string()).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

#[no_mangle]
pub unsafe extern "C" fn converter_job_control_free(control: *mut ConverterJobControl) {
    if !control.is_null() {
        drop(Box::from_raw(control));
    }
}

#[no_mangle]
pub unsafe extern "C" fn converter_job_control_cancel(control: *const ConverterJobControl) {
    if let Some(control) = control.as_ref() {
        control.control.cancel();
    }
}

/// Suspends subsequent chapter boundaries without interrupting the current
/// validated artifact. Cancellation wakes a suspended worker.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_set_paused(
    control: *const ConverterJobControl,
    paused: bool,
) {
    if let Some(control) = control.as_ref() {
        control.control.set_paused(paused);
    }
}

#[no_mangle]
pub unsafe extern "C" fn converter_job_control_set_playback_window(
    control: *const ConverterJobControl,
    current_chapter: usize,
    chapters_ahead: usize,
) {
    if let Some(control) = control.as_ref() {
        control
            .control
            .set_playback_window(current_chapter, chapters_ahead);
    }
}

/// Returns whether a source chapter still belongs to the active playback
/// window. Streaming adapters use this at chunk delivery so seeks can stop an
/// in-flight, now-distant chapter before its audio is persisted.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_chapter_is_in_playback_window(
    control: *const ConverterJobControl,
    chapter_index: usize,
) -> bool {
    control
        .as_ref()
        .is_some_and(|control| control.control.chapter_is_in_playback_window(chapter_index))
}

#[no_mangle]
pub unsafe extern "C" fn converter_job_control_prioritize(
    control: *const ConverterJobControl,
    chapter_index: usize,
) -> bool {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        fail::<()>("invalid null job control".to_owned());
        return false;
    };
    match control.control.prioritize(chapter_index) {
        Ok(()) => true,
        Err(error) => {
            fail::<()>(error.to_string());
            false
        }
    }
}

/// Selects a durable predecessor for a new job before its queue attaches.
/// The ID is copied; the caller may immediately release its UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_set_recovery_job(
    control: *const ConverterJobControl,
    source_job_id: *const c_char,
) -> bool {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        fail::<()>("invalid null job control".to_owned());
        return false;
    };
    let source_job_id = match c_string(source_job_id, "recovery job ID") {
        Ok(value) => value,
        Err(error) => {
            fail::<()>(error);
            return false;
        }
    };
    match control.control.set_recovery_job(&source_job_id) {
        Ok(()) => true,
        Err(error) => {
            fail::<()>(error.to_string());
            false
        }
    }
}

/// Receives a UTF-8 JSON chapter event. The string is borrowed only for the
/// duration of the callback and must be copied by the caller.
pub type ConverterChapterCompletedCallback =
    Option<unsafe extern "C" fn(event_json: *const c_char, context: *mut c_void)>;
pub type ConverterProgressCallback =
    Option<unsafe extern "C" fn(event_json: *const c_char, context: *mut c_void)>;
/// Borrowed audio bytes are valid only for the callback duration. Returning
/// false cancels remaining synthesis before the chapter artifact is published.
pub type ConverterAudioChunkCallback = Option<
    unsafe extern "C" fn(
        source_chapter_index: usize,
        chunk_index: usize,
        audio: *const u8,
        audio_len: usize,
        context: *mut c_void,
    ) -> bool,
>;

fn positional_chapter_selection(
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
fn embedded_chapter_parallelism_cap() -> usize {
    if cfg!(target_os = "macos") || cfg!(target_os = "ios") {
        2
    } else {
        1
    }
}

fn progress_log_line(
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

/// Converts a book through the shared Rust worker and publishes each complete,
/// ffprobe-validated chapter in conversion order. `output_dir` must be the
/// directory named by `job_id`; event strings are valid only during callback.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_job_json(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
) -> *mut c_char {
    convert_job_json(
        handle,
        output_dir,
        job_id,
        chapter_start,
        chapter_end,
        progress_callback,
        callback,
        context,
        None,
        None,
        EmbeddedConversionOptionsV1::default(),
    )
}

/// Additive controlled entry point. Control must be valid during this call's
/// initial clone; cancellation and priority share state with the owned worker.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_controlled_job_json(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
    control: *const ConverterJobControl,
) -> *mut c_char {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        return fail("invalid null job control".to_owned());
    };
    let owned_control = control.control.clone();
    convert_job_json(
        handle,
        output_dir,
        job_id,
        chapter_start,
        chapter_end,
        progress_callback,
        callback,
        context,
        Some(owned_control),
        None,
        EmbeddedConversionOptionsV1 {
            audio_chunks: Some(control.audio_chunks.clone()),
            ..Default::default()
        },
    )
}

/// Controlled playback conversion with ordered per-chunk audio delivery.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_streaming_job_json(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    chapter_callback: ConverterChapterCompletedCallback,
    chunk_callback: ConverterAudioChunkCallback,
    context: *mut c_void,
    control: *const ConverterJobControl,
) -> *mut c_char {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        return fail("invalid null job control".to_owned());
    };
    convert_job_json(
        handle,
        output_dir,
        job_id,
        chapter_start,
        chapter_end,
        progress_callback,
        chapter_callback,
        context,
        Some(control.control.clone()),
        chunk_callback,
        EmbeddedConversionOptionsV1 {
            audio_chunks: Some(control.audio_chunks.clone()),
            ..Default::default()
        },
    )
}

/// Streaming conversion with explicit per-job engine selection. The absent
/// or invalid engine keeps the established Edge default.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_streaming_job_options_json_v1(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    options_json: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    chapter_callback: ConverterChapterCompletedCallback,
    chunk_callback: ConverterAudioChunkCallback,
    context: *mut c_void,
    control: *const ConverterJobControl,
) -> *mut c_char {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        return fail("invalid null job control".to_owned());
    };
    let options_json = match c_string(options_json, "conversion options") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let options: EmbeddedConversionOptionsV1 = match serde_json::from_str(&options_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid conversion options JSON: {error}")),
    };
    convert_job_json(
        handle,
        output_dir,
        job_id,
        chapter_start,
        chapter_end,
        progress_callback,
        chapter_callback,
        context,
        Some(control.control.clone()),
        chunk_callback,
        EmbeddedConversionOptionsV1 {
            audio_chunks: Some(control.audio_chunks.clone()),
            ..options
        },
    )
}

/// Whole-book conversion with an explicit per-job engine choice.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_job_options_json_v1(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    options_json: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    chapter_callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
) -> *mut c_char {
    let options_json = match c_string(options_json, "conversion options") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let options: EmbeddedConversionOptionsV1 = match serde_json::from_str(&options_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid conversion options JSON: {error}")),
    };
    convert_job_json(
        handle,
        output_dir,
        job_id,
        chapter_start,
        chapter_end,
        progress_callback,
        chapter_callback,
        context,
        None,
        None,
        options,
    )
}

/// Conversion with immutable per-job voice options and an independently cancellable control.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_controlled_job_options_json_v1(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    options_json: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    chapter_callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
    control: *const ConverterJobControl,
) -> *mut c_char {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        return fail("invalid null job control".to_owned());
    };
    let options_json = match c_string(options_json, "conversion options") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let options: EmbeddedConversionOptionsV1 = match serde_json::from_str(&options_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid conversion options JSON: {error}")),
    };
    convert_job_json(
        handle,
        output_dir,
        job_id,
        chapter_start,
        chapter_end,
        progress_callback,
        chapter_callback,
        context,
        Some(control.control.clone()),
        None,
        EmbeddedConversionOptionsV1 {
            audio_chunks: Some(control.audio_chunks.clone()),
            ..options
        },
    )
}

unsafe fn convert_job_json(
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

fn embedded_engine_from_value(value: Option<&str>) -> String {
    match value
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "piper" => "piper".to_owned(),
        "system" => "system".to_owned(),
        _ => "edge".to_owned(),
    }
}

fn resolve_piper_model_paths(
    options: &EmbeddedConversionOptionsV1,
) -> Result<(std::path::PathBuf, std::path::PathBuf), String> {
    let Some(model_id) = options.model_id.as_deref() else {
        return Err("Piper requires an explicitly installed local model.".to_owned());
    };
    // Validation may run before the session supplies its managed model root.
    // Actual conversion fills that root from AppConfig before resolving paths.
    let root = match options.models_root.as_deref() {
        Some(root) => root,
        None if options
            .tts_preferences
            .as_ref()
            .is_some_and(|p| p.continues_native()) =>
        {
            "."
        }
        None => return Err("Piper requires an explicitly installed local model.".into()),
    };
    for value in [
        model_id,
        options.model_path.as_deref().unwrap_or("model.onnx"),
        options
            .model_config_path
            .as_deref()
            .unwrap_or("model.onnx.json"),
    ] {
        if value.is_empty()
            || Path::new(value)
                .components()
                .any(|component| !matches!(component, std::path::Component::Normal(_)))
            || value.contains(char::from(92))
        {
            return Err(
                "Piper model paths must remain inside the installed model directory".into(),
            );
        }
    }
    if Path::new(model_id).components().count() != 1 {
        return Err("Invalid Piper model ID".into());
    }
    let model = Path::new(root)
        .join(model_id)
        .join(options.model_path.as_deref().unwrap_or("model.onnx"));
    let config = model.with_file_name(
        options
            .model_config_path
            .as_deref()
            .unwrap_or("model.onnx.json"),
    );
    if (!model.is_file() || !config.is_file())
        && !options
            .tts_preferences
            .as_ref()
            .is_some_and(|p| p.continues_native())
    {
        return Err(format!(
            "Piper model or voice config is not installed: {}",
            model.display()
        ));
    }
    Ok((model, config))
}

/// Returns the most recent error for the current thread, transferring ownership to the caller.
#[no_mangle]
pub unsafe extern "C" fn converter_last_error() -> *mut c_char {
    LAST_ERROR.with(|error| match error.borrow_mut().take() {
        Some(error) => CString::new(error).map_or(ptr::null_mut(), CString::into_raw),
        None => ptr::null_mut(),
    })
}

/// Frees an opaque session handle. Null is accepted.
#[no_mangle]
pub unsafe extern "C" fn converter_session_free(handle: *mut ConverterSession) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Frees a string returned by this crate. Null is accepted.
#[no_mangle]
pub unsafe extern "C" fn converter_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

/// Returns the shared TTS model catalog as an owned JSON string.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_models_json() -> *mut c_char {
    clear_last_error();
    let value = match serde_json::to_string(converter_core::model_catalog::MODELS) {
        Ok(value) => value,
        Err(error) => return fail(error.to_string()),
    };
    CString::new(value).map_or_else(
        |_| fail("model catalog contains an interior NUL byte".to_owned()),
        CString::into_raw,
    )
}

/// Returns the current durable Rust coordinator record for a job. Clients poll
/// this small JSON payload for live conversion status; no HTTP or Python path
/// is involved.
#[no_mangle]
pub unsafe extern "C" fn converter_job_log_json(job_id: *const c_char) -> *mut c_char {
    clear_last_error();
    let job_id = match c_string(job_id, "job id") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let paths = resolve_paths_from(
        std::env::vars(),
        Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf(),
    );
    let manager = match converter_core::jobs::JobManager::new(paths.jobs_dir) {
        Ok(manager) => manager,
        Err(error) => return fail(error.to_string()),
    };
    match manager.load(&job_id) {
        Ok(record) => match serde_json::to_string(&json!([
            format!("job {}: {:?}", record.job_id, record.state),
            format!("progress: {}", record.progress),
            format!("updated: {}", record.updated_at),
        ])) {
            Ok(value) => CString::new(value).map_or_else(
                |_| fail("job log contains an interior NUL byte".to_owned()),
                CString::into_raw,
            ),
            Err(error) => fail(error.to_string()),
        },
        Err(error) => fail(error.to_string()),
    }
}

/// Inspects whether an installed local runtime is ready for inference.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_runtime_status_json(
    engine: *const c_char,
    model_root: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let engine = match c_string(engine, "engine") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let model_root = match c_string(model_root, "model root") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let status = match converter_core::tts_runtime::inspect_runtime(&engine, Path::new(&model_root))
    {
        Ok(status) => status,
        Err(error) => return fail(error.to_string()),
    };
    match serde_json::to_string(&status) {
        Ok(value) => CString::new(value).map_or_else(
            |_| fail("runtime status contains an interior NUL byte".to_owned()),
            CString::into_raw,
        ),
        Err(error) => fail(error.to_string()),
    }
}

/// Synthesizes one text payload with the optional sherpa Kokoro runtime.
/// Returns an owned WAV byte buffer; release it with `converter_bytes_free`.
#[cfg(feature = "kokoro-sherpa-runtime")]
#[no_mangle]
pub unsafe extern "C" fn converter_tts_synthesize_wav(
    model_root: *const c_char,
    text: *const c_char,
    out_len: *mut usize,
) -> *mut u8 {
    clear_last_error();
    if out_len.is_null() {
        return fail::<*mut u8>("output length pointer is null".to_owned());
    }
    let model_root = match c_string(model_root, "model root") {
        Ok(value) => value,
        Err(error) => return fail::<*mut u8>(error),
    };
    let text = match c_string(text, "text") {
        Ok(value) => value,
        Err(error) => return fail::<*mut u8>(error),
    };
    let wav = match converter_core::kokoro_sherpa::synthesize_wav(Path::new(&model_root), &text) {
        Ok(wav) => wav,
        Err(error) => return fail::<*mut u8>(error.to_string()),
    };
    let mut wav = wav.into_boxed_slice();
    let length = wav.len();
    let pointer = wav.as_mut_ptr();
    std::mem::forget(wav);
    *out_len = length;
    pointer
}

/// Frees a byte buffer returned by a converter ABI function.
#[no_mangle]
pub unsafe extern "C" fn converter_bytes_free(pointer: *mut u8, length: usize) {
    if !pointer.is_null() {
        drop(Vec::from_raw_parts(pointer, length, length));
    }
}

/// Returns the default local engine for a language and platform.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_default_engine(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
) -> *mut c_char {
    clear_last_error();
    let language = match c_string(language, "language") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let platform = match c_string(platform, "platform") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let platform = match platform.to_ascii_lowercase().as_str() {
        "android" => converter_core::model_catalog::ModelPlatform::Android,
        "ios" => converter_core::model_catalog::ModelPlatform::Ios,
        "macos" => converter_core::model_catalog::ModelPlatform::Macos,
        "linux" => converter_core::model_catalog::ModelPlatform::Linux,
        "windows" => converter_core::model_catalog::ModelPlatform::Windows,
        other => return fail(format!("unsupported platform: {other}")),
    };
    let api = (android_api > 0).then_some(android_api);
    CString::new(converter_core::model_catalog::default_engine(
        &language, platform, api,
    ))
    .map_or_else(
        |_| fail("default engine contains an interior NUL byte".to_owned()),
        CString::into_raw,
    )
}

/// Selects an engine from installed models that the client has runtime-tested.
/// Both JSON arguments must be arrays of model IDs. An empty or unverified
/// readiness list intentionally returns `"none"`.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_installed_ready_engine(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
    installed_model_ids_json: *const c_char,
    ready_model_ids_json: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let language = match c_string(language, "language") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let platform = match c_string(platform, "platform") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let installed_json = match c_string(installed_model_ids_json, "installed model IDs") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let ready_json = match c_string(ready_model_ids_json, "ready model IDs") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let installed: Vec<String> = match serde_json::from_str(&installed_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid installed model IDs JSON: {error}")),
    };
    let ready: Vec<String> = match serde_json::from_str(&ready_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid ready model IDs JSON: {error}")),
    };
    let installed: Vec<&str> = installed.iter().map(String::as_str).collect();
    let ready: Vec<&str> = ready.iter().map(String::as_str).collect();
    let platform = match platform.to_ascii_lowercase().as_str() {
        "android" => converter_core::model_catalog::ModelPlatform::Android,
        "ios" => converter_core::model_catalog::ModelPlatform::Ios,
        "macos" => converter_core::model_catalog::ModelPlatform::Macos,
        "linux" => converter_core::model_catalog::ModelPlatform::Linux,
        "windows" => converter_core::model_catalog::ModelPlatform::Windows,
        other => return fail(format!("unsupported platform: {other}")),
    };
    let api = (android_api > 0).then_some(android_api);
    let engine = converter_core::model_catalog::installed_ready_engine(
        &language, platform, api, &installed, &ready,
    )
    .unwrap_or("none");
    CString::new(engine).map_or_else(
        |_| fail("selected engine contains an interior NUL byte".to_owned()),
        CString::into_raw,
    )
}

/// Installs a catalog model after downloading and verifying its SHA-256.
/// This blocking ABI is intended for a background worker in each client.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install(
    model_id: *const c_char,
    url: *const c_char,
    sha256: *const c_char,
    root: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let model_id = match c_string(model_id, "model id") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let url = match c_string(url, "model URL") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let sha256 = match c_string(sha256, "model SHA-256") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let root = match c_string(root, "model storage root") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let model = match converter_core::model_catalog::MODELS
        .iter()
        .find(|model| model.id == model_id)
    {
        Some(model) => model,
        None => return fail(format!("unknown TTS model: {model_id}")),
    };
    let store = converter_core::model_store::ModelStore::new(root);
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return fail(format!("failed to start model installer: {error}")),
    };
    match runtime.block_on(store.install(model, Some(&url), Some(&sha256))) {
        Ok(installed) => match CString::new(installed.path.to_string_lossy().as_bytes()) {
            Ok(value) => value.into_raw(),
            Err(_) => fail("installed model path contains an interior NUL byte".to_owned()),
        },
        Err(error) => fail(error.to_string()),
    }
}

/// Installs a multi-file model manifest. The JSON must contain an array of
/// `{name,url,sha256}` artifacts; publication occurs only after all files pass.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_manifest(
    model_id: *const c_char,
    artifacts_json: *const c_char,
    root: *const c_char,
) -> *mut c_char {
    clear_last_error();
    #[derive(Deserialize)]
    struct ArtifactInput {
        name: String,
        url: String,
        sha256: String,
    }
    let model_id = match c_string(model_id, "model id") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let artifacts_json = match c_string(artifacts_json, "model artifacts JSON") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let root = match c_string(root, "model storage root") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    if !converter_core::model_catalog::MODELS
        .iter()
        .any(|model| model.id == model_id)
    {
        return fail(format!("unknown TTS model: {model_id}"));
    }
    let artifacts: Vec<ArtifactInput> = match serde_json::from_str(&artifacts_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid model artifacts JSON: {error}")),
    };
    let manifest = converter_core::model_store::ModelManifest {
        model_id: model_id.clone(),
        artifacts: artifacts
            .into_iter()
            .map(|artifact| converter_core::model_store::ModelArtifact {
                name: artifact.name,
                url: artifact.url,
                sha256: artifact.sha256,
            })
            .collect(),
    };
    let store = converter_core::model_store::ModelStore::new(&root);
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return fail(format!("failed to start model installer: {error}")),
    };
    match runtime.block_on(store.install_manifest(&manifest)) {
        Ok(_) => match CString::new(store.root().join(model_id).to_string_lossy().as_bytes()) {
            Ok(value) => value.into_raw(),
            Err(_) => fail("installed model path contains an interior NUL byte".to_owned()),
        },
        Err(error) => fail(error.to_string()),
    }
}

/// Installs the verified manifest embedded in the shared catalog.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_catalog_manifest(
    model_id: *const c_char,
    root: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let model_id = match c_string(model_id, "model id") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let root = match c_string(root, "model storage root") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let store = converter_core::model_store::ModelStore::new(&root);
    let manifest = match converter_core::model_store::ModelStore::catalog_manifest(&model_id) {
        Ok(manifest) => manifest,
        Err(error) => return fail(error.to_string()),
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return fail(format!("failed to start model installer: {error}")),
    };
    match runtime.block_on(store.install_manifest(&manifest)) {
        Ok(_) => CString::new(store.root().join(model_id).to_string_lossy().as_bytes())
            .map_or_else(
                |_| fail("installed model path contains an interior NUL byte".to_owned()),
                CString::into_raw,
            ),
        Err(error) => fail(error.to_string()),
    }
}

/// Removes a catalog model from the supplied storage root.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_remove(
    model_id: *const c_char,
    root: *const c_char,
) -> bool {
    clear_last_error();
    let model_id = match c_string(model_id, "model id") {
        Ok(value) => value,
        Err(error) => {
            fail::<()>(error);
            return false;
        }
    };
    let root = match c_string(root, "model storage root") {
        Ok(value) => value,
        Err(error) => {
            fail::<()>(error);
            return false;
        }
    };
    let store = converter_core::model_store::ModelStore::new(root);
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            fail::<()>(error.to_string());
            return false;
        }
    };
    match runtime.block_on(store.remove(&model_id)) {
        Ok(()) => true,
        Err(error) => {
            fail::<()>(error.to_string());
            false
        }
    }
}

/// Returns the installed model metadata JSON, or null when the model is absent.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_metadata(
    model_id: *const c_char,
    root: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let model_id = match c_string(model_id, "model id") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let root = match c_string(root, "model storage root") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let store = converter_core::model_store::ModelStore::new(root);
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return fail(format!("failed to read model metadata: {error}")),
    };
    match runtime.block_on(store.installed_metadata(&model_id)) {
        Ok(Some(value)) => match CString::new(value) {
            Ok(value) => value.into_raw(),
            Err(_) => fail("model metadata contains an interior NUL byte".to_owned()),
        },
        Ok(None) => ptr::null_mut(),
        Err(error) => fail(error.to_string()),
    }
}

#[repr(C)]
pub struct PiperStatus {
    pub runtime_loaded: bool,
    pub model_available: bool,
    pub abi_compatible: bool,
    pub engine_ready: bool,
}

pub type PiperRuntimeStatusC = PiperStatus;

#[cfg(not(feature = "piper-runtime"))]
#[no_mangle]
pub unsafe extern "C" fn piper_runtime_status() -> PiperRuntimeStatusC {
    let status = piper::piper_runtime_status();
    PiperStatus {
        runtime_loaded: status.runtime_loaded,
        model_available: status.model_available,
        abi_compatible: status.abi_compatible,
        engine_ready: status.engine_ready,
    }
}

#[cfg(not(feature = "piper-runtime"))]
#[no_mangle]
pub unsafe extern "C" fn piper_runtime_init(model: *const c_char, config: *const c_char) -> bool {
    clear_last_error();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let model = c_string(model, "Piper model")?;
        let config = c_string(config, "Piper config")?;
        piper::piper_runtime_init(Path::new(&model), Path::new(&config))
            .map_err(|error| error.to_string())
    }));
    match result {
        Ok(Ok(())) => true,
        Ok(Err(error)) => {
            fail::<()>(error);
            false
        }
        Err(_) => {
            fail::<()>("Piper runtime initialization panicked".into());
            false
        }
    }
}

#[cfg(not(feature = "piper-runtime"))]
#[no_mangle]
pub unsafe extern "C" fn piper_synthesize(text: *const c_char, output: *const c_char) -> bool {
    clear_last_error();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let text = c_string(text, "Piper text")?;
        let output = c_string(output, "Piper output")?;
        piper::piper_synthesize(&text, Path::new(&output))
            .map(|_| ())
            .map_err(|error| error.to_string())
    }));
    match result {
        Ok(Ok(())) => true,
        Ok(Err(error)) => {
            fail::<()>(error);
            false
        }
        Err(_) => {
            fail::<()>("Piper synthesis panicked".into());
            false
        }
    }
}

#[cfg(not(feature = "piper-runtime"))]
#[no_mangle]
pub extern "C" fn piper_runtime_shutdown() {
    piper::piper_runtime_shutdown();
}

/// Registers the platform runtime through a conservative status-only bridge.
#[no_mangle]
pub extern "C" fn piper_runtime_register_unavailable() {
    piper::register_runtime(Arc::new(UnavailablePiperRuntime));
}
struct UnavailablePiperRuntime;
impl piper::PiperRuntime for UnavailablePiperRuntime {
    fn status(&self) -> piper::PiperRuntimeStatus {
        piper::PiperRuntimeStatus {
            runtime_loaded: false,
            model_available: false,
            abi_compatible: false,
            engine_ready: false,
        }
    }
    fn init(&self, _: &Path, _: &Path) -> Result<(), piper::PiperError> {
        Err(piper::PiperError::RuntimeUnavailable(
            "Native Piper implementation is not linked".into(),
        ))
    }
    fn synthesize(&self, _: &str, _: &Path) -> Result<(), piper::PiperError> {
        self.init(Path::new(""), Path::new(""))
    }
    fn shutdown(&self) {}
}

#[cfg(feature = "piper-runtime")]
#[no_mangle]
pub extern "C" fn piper_runtime_register_embedded() {
    piper::register_runtime(Arc::new(EmbeddedPiperRuntime));
}

/// Configure the native phonemizer for Rust hosts using the same embedded provider.
#[cfg(feature = "piper-runtime")]
pub fn configure_piper_data_directory(path: &Path) -> Result<(), String> {
    piper_runtime::set_espeak_data_directory(path)
}

#[cfg(feature = "piper-runtime")]
struct EmbeddedPiperRuntime;

#[cfg(feature = "piper-runtime")]
impl converter_core::piper::PiperRuntime for EmbeddedPiperRuntime {
    fn status(&self) -> converter_core::piper::PiperRuntimeStatus {
        let native = piper_runtime::piper_runtime_status();
        converter_core::piper::PiperRuntimeStatus {
            runtime_loaded: native.runtime_loaded != 0,
            model_available: native.model_available != 0,
            abi_compatible: native.abi_compatible != 0,
            engine_ready: native.engine_ready != 0,
        }
    }

    fn init(&self, model: &Path, config: &Path) -> Result<(), converter_core::piper::PiperError> {
        let model = CString::new(model.to_string_lossy().as_bytes())
            .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
        let config = CString::new(config.to_string_lossy().as_bytes())
            .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
        let mut error = vec![0 as std::ffi::c_char; 2048];
        if unsafe {
            piper_runtime::piper_runtime_init(
                model.as_ptr(),
                config.as_ptr(),
                error.as_mut_ptr(),
                error.len() as u32,
            )
        } == 0
        {
            return Err(converter_core::piper::PiperError::Synthesis(c_error(
                unsafe { std::slice::from_raw_parts(error.as_ptr().cast::<u8>(), error.len()) },
            )));
        }
        Ok(())
    }

    fn synthesize(
        &self,
        text: &str,
        output: &Path,
    ) -> Result<(), converter_core::piper::PiperError> {
        let text = CString::new(text)
            .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
        let output = CString::new(output.to_string_lossy().as_bytes())
            .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
        let mut error = vec![0 as std::ffi::c_char; 2048];
        if unsafe {
            piper_runtime::piper_synthesize(
                text.as_ptr(),
                output.as_ptr(),
                error.as_mut_ptr(),
                error.len() as u32,
            )
        } == 0
        {
            return Err(converter_core::piper::PiperError::Synthesis(c_error(
                unsafe { std::slice::from_raw_parts(error.as_ptr().cast::<u8>(), error.len()) },
            )));
        }
        Ok(())
    }

    fn shutdown(&self) {
        piper_runtime::piper_runtime_shutdown();
    }
}

#[cfg(feature = "piper-runtime")]
fn c_error(error: &[u8]) -> String {
    String::from_utf8_lossy(error)
        .trim_end_matches('\0')
        .to_owned()
}

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

fn clear_last_error() {
    LAST_ERROR.with(|error| error.borrow_mut().take());
}

fn fail<T>(error: String) -> T {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(error));
    // This function is only called at null-returning ABI boundaries.
    unsafe { std::mem::zeroed() }
}

unsafe fn c_string(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("invalid null {name}"));
    }
    CStr::from_ptr(value)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| format!("{name} must be valid UTF-8"))
}

fn metadata_json(
    metadata: &EmbeddedBookMetadata,
    structure: &converter_core::structure::StructureVerification,
) -> String {
    json!({
        "title": metadata.title,
        "author": metadata.author,
        "language": metadata.language,
        "chapters": metadata.chapters.iter().map(|chapter| json!({
            "index": chapter.index,
            "name": chapter.name,
            "sourcePath": chapter.source_path,
            "textChars": chapter.text_chars,
            "text": chapter.text,
            "level": chapter.level,
        })).collect::<Vec<_>>(),
        "structure": {
            "source": format!("{:?}", structure.source),
            "verified": structure.verified,
            "requiresConfirmation": structure.requires_confirmation(),
            "mappedTocItems": structure.mapped_toc_items,
            "totalTocItems": structure.total_toc_items,
            "warnings": structure.warnings.iter().map(|warning| json!({
                "code": warning.code,
                "message": warning.message,
            })).collect::<Vec<_>>(),
        },
    })
    .to_string()
}

#[cfg(any(
    all(target_os = "android", feature = "android-jni"),
    all(test, feature = "android-jni")
))]
mod android_jni {
    use super::*;
    use jni::{
        objects::{GlobalRef, JClass, JObject, JString, JValue},
        sys::{jboolean, jint, jlong, jstring},
        JNIEnv, JavaVM,
    };

    struct AndroidPlatformSpeech {
        vm: JavaVM,
        activity: GlobalRef,
        input_path: String,
    }

    fn android_controls() -> &'static std::sync::Mutex<HashMap<String, ConversionControl>> {
        static CONTROLS: std::sync::OnceLock<std::sync::Mutex<HashMap<String, ConversionControl>>> =
            std::sync::OnceLock::new();
        CONTROLS.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePrepareConversion(
        mut env: JNIEnv<'_>,
        _activity: JObject<'_>,
        request: JString<'_>,
    ) {
        if let Ok(request) = read_string(&mut env, request) {
            android_controls()
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .entry(request)
                .or_default();
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeCancelConversion(
        mut env: JNIEnv<'_>,
        _activity: JObject<'_>,
        request: JString<'_>,
    ) {
        if let Ok(request) = read_string(&mut env, request) {
            if let Some(control) = android_controls()
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .get(&request)
                .cloned()
            {
                control.cancel();
            }
        }
    }

    struct BorrowedCancellation<'a>(&'a (dyn Fn() -> bool + Sync));

    impl converter_core::platform_tts::PlatformTts for AndroidPlatformSpeech {
        fn synthesize_wav(
            &self,
            text: &str,
            language: &str,
            output: &Path,
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), String> {
            let mut env = self
                .vm
                .attach_current_thread()
                .map_err(|error| error.to_string())?;
            let text = JObject::from(env.new_string(text).map_err(|error| error.to_string())?);
            let language = JObject::from(
                env.new_string(language)
                    .map_err(|error| error.to_string())?,
            );
            let output = JObject::from(
                env.new_string(output.to_string_lossy())
                    .map_err(|error| error.to_string())?,
            );
            let input = JObject::from(
                env.new_string(&self.input_path)
                    .map_err(|error| error.to_string())?,
            );
            let cancellation = BorrowedCancellation(cancelled);
            let result = env.call_method(
                self.activity.as_obj(),
                "synthesizeNativeSpeech",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;J)Z",
                &[
                    JValue::Object(&text),
                    JValue::Object(&language),
                    JValue::Object(&output),
                    JValue::Object(&input),
                    JValue::Long(&cancellation as *const BorrowedCancellation<'_> as jlong),
                ],
            );
            if env.exception_check().unwrap_or(false) {
                let exception = env
                    .exception_occurred()
                    .map_err(|error| error.to_string())?;
                env.exception_clear().map_err(|error| error.to_string())?;
                let message = env
                    .call_method(exception, "toString", "()Ljava/lang/String;", &[])
                    .and_then(|value| value.l())
                    .ok()
                    .and_then(|value| read_string(&mut env, JString::from(value)).ok())
                    .unwrap_or_else(|| "Android offline speech failed".to_owned());
                return Err(message);
            }
            match result.map_err(|error| error.to_string())?.z() {
                Ok(true) => Ok(()),
                Ok(false) => Err("Android offline speech produced no audio".into()),
                Err(error) => Err(error.to_string()),
            }
        }
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePlatformSpeechCancelled(
        _env: JNIEnv<'_>,
        _activity: JObject<'_>,
        context: jlong,
    ) -> jboolean {
        if context == 0 {
            return 1;
        }
        let cancellation = &*(context as *const BorrowedCancellation<'_>);
        (cancellation.0)() as jboolean
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativePlatformSpeechCancelled(
        env: JNIEnv<'_>,
        worker: JObject<'_>,
        context: jlong,
    ) -> jboolean {
        Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePlatformSpeechCancelled(
            env, worker, context,
        )
    }

    fn read_string(env: &mut JNIEnv<'_>, value: JString<'_>) -> Result<String, String> {
        env.get_string(&value)
            .map(|value| value.to_string_lossy().into_owned())
            .map_err(|error| error.to_string())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperStatus(
        env: JNIEnv<'_>,
        _class: JClass<'_>,
    ) -> jstring {
        #[cfg(feature = "piper-runtime")]
        piper_runtime_register_embedded();
        let status = {
            #[cfg(feature = "piper-runtime")]
            {
                let status = piper_runtime::piper_runtime_status();
                PiperStatus {
                    runtime_loaded: status.runtime_loaded != 0,
                    model_available: status.model_available != 0,
                    abi_compatible: status.abi_compatible != 0,
                    engine_ready: status.engine_ready != 0,
                }
            }
            #[cfg(not(feature = "piper-runtime"))]
            {
                unsafe { piper_runtime_status() }
            }
        };
        let value = serde_json::json!({
            "runtimeLoaded": status.runtime_loaded,
            "modelAvailable": status.model_available,
            "abiCompatible": status.abi_compatible,
            "engineReady": status.engine_ready,
        })
        .to_string();
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesizeWithOptions(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        text: JString<'_>,
        output: JString<'_>,
        options_json: JString<'_>,
    ) -> jboolean {
        let result = (|| -> Result<(), String> {
            let text = read_string(&mut env, text)?;
            let output = read_string(&mut env, output)?;
            let json = read_string(&mut env, options_json)?;
            let mut options: EmbeddedConversionOptionsV1 =
                serde_json::from_str(&json).map_err(|e| e.to_string())?;
            if let Some(preferences) = &options.tts_preferences {
                preferences.validate(options.language.as_deref())?;
                if preferences.primary.engine != "piper" {
                    return Err("Piper sample requires a Piper primary".into());
                }
                options.model_id = preferences.primary.model_id.clone();
            }
            let (model, config) = resolve_piper_model_paths(&options)?;
            #[cfg(feature = "piper-runtime")]
            {
                if let Some(directory) = options.espeak_data_directory.as_deref() {
                    configure_piper_data_directory(Path::new(directory))?;
                }
                piper_runtime_register_embedded();
            }
            let config = converter_core::piper::PiperConfig::new(model, config);
            converter_core::piper::synthesize(
                &config,
                &text,
                Path::new(&output),
                &converter_core::piper::CancellationToken::default(),
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })();
        match result {
            Ok(()) => 1,
            Err(error) => fail::<jboolean>(error),
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesize(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        text: JString<'_>,
        output: JString<'_>,
    ) -> jboolean {
        let text = match read_string(&mut env, text) {
            Ok(value) => value,
            Err(error) => return fail::<jboolean>(error),
        };
        let output = match read_string(&mut env, output) {
            Ok(value) => value,
            Err(error) => return fail::<jboolean>(error),
        };
        let text = std::ffi::CString::new(text).unwrap();
        let output = std::ffi::CString::new(output).unwrap();
        let model = std::ffi::CString::new("/data/user/0/com.pietrocode.epubtomp3.flutter_app/app_flutter/tts-models/en_US-lessac-low.onnx/model.bin").unwrap();
        let config = std::ffi::CString::new("/data/user/0/com.pietrocode.epubtomp3.flutter_app/app_flutter/tts-models/en_US-lessac-low.onnx/model.json").unwrap();
        #[cfg(feature = "piper-runtime")]
        {
            let mut error = vec![0_u8; 2048];
            let initialized = piper_runtime::piper_runtime_init(
                model.as_ptr(),
                config.as_ptr(),
                error.as_mut_ptr(),
                error.len() as u32,
            );
            if initialized == 0 {
                let message = unsafe { std::ffi::CStr::from_ptr(error.as_ptr()) }
                    .to_string_lossy()
                    .into_owned();
                fail::<jboolean>(message);
                return 0;
            }
            let synthesized = piper_runtime::piper_synthesize(
                text.as_ptr(),
                output.as_ptr(),
                error.as_mut_ptr(),
                error.len() as u32,
            );
            if synthesized == 0 {
                let message = unsafe { std::ffi::CStr::from_ptr(error.as_ptr()) }
                    .to_string_lossy()
                    .into_owned();
                fail::<jboolean>(message);
                return 0;
            }
            return 1;
        }
        #[cfg(not(feature = "piper-runtime"))]
        unsafe {
            if piper_runtime_init(model.as_ptr(), config.as_ptr()) {
                if piper_synthesize(text.as_ptr(), output.as_ptr()) {
                    1
                } else {
                    0
                }
            } else {
                0
            }
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeParse(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        path: JString<'_>,
    ) -> jstring {
        #[cfg(feature = "piper-runtime")]
        piper_runtime_register_embedded();
        let path = match read_string(&mut env, path) {
            Ok(path) => path,
            Err(error) => {
                return env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let path = match CString::new(path) {
            Ok(path) => path,
            Err(_) => return std::ptr::null_mut(),
        };
        let handle = unsafe { converter_session_open(path.as_ptr()) };
        eprintln!("converter-ffi: open returned");
        if handle.is_null() {
            eprintln!("converter-ffi: open failed");
            return std::ptr::null_mut();
        }
        let metadata = unsafe { converter_session_metadata_json(handle) };
        let result = if metadata.is_null() {
            std::ptr::null_mut()
        } else {
            let value = unsafe { CStr::from_ptr(metadata) }
                .to_string_lossy()
                .into_owned();
            unsafe { converter_string_free(metadata) };
            env.new_string(value)
                .map_or(std::ptr::null_mut(), |value| value.into_raw())
        };
        unsafe { converter_session_free(handle as *mut ConverterSession) };
        result
    }

    fn persist_android_chunk(
        root: &Path,
        chapter: usize,
        index: usize,
        audio: &[u8],
        cancelled: &dyn Fn() -> bool,
    ) -> Result<std::path::PathBuf, String> {
        use std::io::Write;
        if cancelled() {
            return Err("Android audio chunk cancelled".into());
        }
        let directory = root.join(chapter.to_string());
        std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
        let path = directory.join(format!("{index:06}.mp3"));
        if path.exists() {
            return Err("Android audio chunk path already exists".into());
        }
        let pending = path.with_extension("mp3.pending");
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&pending)
            .map_err(|error| error.to_string())?;
        struct RemovePending(std::path::PathBuf);
        impl Drop for RemovePending {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _cleanup = RemovePending(pending.clone());
        file.write_all(audio).map_err(|error| error.to_string())?;
        file.sync_all().map_err(|error| error.to_string())?;
        drop(file);
        converter_core::audio::validate_audio(&pending, 100).map_err(|error| error.to_string())?;
        if cancelled() {
            return Err("Android audio chunk cancelled".into());
        }
        std::fs::rename(&pending, &path).map_err(|error| error.to_string())?;
        Ok(path)
    }

    #[cfg(test)]
    mod chunk_tests {
        use super::*;
        const AUDIO: &[u8] = include_bytes!("../../../tests/fixtures/audio/mono-24000-48k.mp3");
        #[test]
        fn platform_chunk_publishes_valid_immutable_audio_without_pending_files() {
            let temp = tempfile::tempdir().unwrap();
            let path = persist_android_chunk(temp.path(), 8, 0, AUDIO, &|| false).unwrap();
            assert_eq!(path, temp.path().join("8/000000.mp3"));
            assert_eq!(std::fs::read(&path).unwrap(), AUDIO);
            assert!(!path.with_extension("mp3.pending").exists());
            assert!(persist_android_chunk(temp.path(), 8, 0, AUDIO, &|| false).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), AUDIO);
        }
        #[test]
        fn platform_chunk_rejects_invalid_or_cancelled_audio_before_publication() {
            let temp = tempfile::tempdir().unwrap();
            assert!(persist_android_chunk(temp.path(), 0, 0, b"Invalid audio", &|| false).is_err());
            assert!(!temp.path().join("0/000000.mp3").exists());
            assert!(!temp.path().join("0/000000.mp3.pending").exists());
            let calls = std::sync::atomic::AtomicUsize::new(0);
            assert!(persist_android_chunk(temp.path(), 0, 0, AUDIO, &|| calls
                .fetch_add(1, std::sync::atomic::Ordering::AcqRel)
                > 0)
            .is_err());
            assert!(!temp.path().join("0/000000.mp3").exists());
            assert!(!temp.path().join("0/000000.mp3.pending").exists());
        }
    }

    struct AndroidAudioChunks {
        vm: JavaVM,
        activity: GlobalRef,
        request_id: String,
        root: std::path::PathBuf,
        control: ConversionControl,
        delivered: std::sync::atomic::AtomicUsize,
    }

    impl AndroidAudioChunks {
        fn dispatch(&self, chapter: usize, index: usize, audio: &[u8]) -> bool {
            if self.control.cancellation_token().is_cancelled() || audio.is_empty() {
                return false;
            }
            let result = (|| -> Result<bool, String> {
                let path = persist_android_chunk(&self.root, chapter, index, audio, &|| {
                    self.control.cancellation_token().is_cancelled()
                })?;
                let mut env = self
                    .vm
                    .attach_current_thread()
                    .map_err(|error| error.to_string())?;
                let request = JObject::from(
                    env.new_string(&self.request_id)
                        .map_err(|error| error.to_string())?,
                );
                let output = JObject::from(
                    env.new_string(path.to_string_lossy())
                        .map_err(|error| error.to_string())?,
                );
                let accepted = env
                    .call_method(
                        self.activity.as_obj(),
                        "onNativeAudioChunk",
                        "(Ljava/lang/String;IILjava/lang/String;)Z",
                        &[
                            JValue::Object(&request),
                            JValue::Int(chapter.try_into().map_err(|_| "Chapter index overflow")?),
                            JValue::Int(index.try_into().map_err(|_| "Chunk index overflow")?),
                            JValue::Object(&output),
                        ],
                    )
                    .map_err(|error| error.to_string())?
                    .z()
                    .map_err(|error| error.to_string())?;
                if accepted {
                    self.delivered
                        .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
                }
                Ok(accepted)
            })();
            if let Err(error) = &result {
                eprintln!("Android audio chunk delivery failed: {error}");
            }
            result.unwrap_or(false)
        }
    }

    unsafe extern "C" fn android_audio_chunk(
        chapter: usize,
        index: usize,
        audio: *const u8,
        length: usize,
        context: *mut c_void,
    ) -> bool {
        if context.is_null() || audio.is_null() || length == 0 {
            return false;
        }
        // The C ABI joins every conversion worker before this borrowed context is dropped.
        (&*context.cast::<AndroidAudioChunks>()).dispatch(
            chapter,
            index,
            std::slice::from_raw_parts(audio, length),
        )
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvert(
        env: JNIEnv<'_>,
        activity: JObject<'_>,
        path: JString<'_>,
        output: JString<'_>,
        chapter_start: jint,
        chapter_end: jint,
    ) -> jstring {
        convert_android(
            env,
            activity,
            path,
            output,
            chapter_start,
            chapter_end,
            false,
            None,
        )
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvertStreaming(
        env: JNIEnv<'_>,
        activity: JObject<'_>,
        path: JString<'_>,
        output: JString<'_>,
        chapter_start: jint,
        chapter_end: jint,
    ) -> jstring {
        convert_android(
            env,
            activity,
            path,
            output,
            chapter_start,
            chapter_end,
            true,
            None,
        )
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvertWithOptions(
        mut env: JNIEnv<'_>,
        activity: JObject<'_>,
        path: JString<'_>,
        output: JString<'_>,
        chapter_start: jint,
        chapter_end: jint,
        options_json: JString<'_>,
        streaming: jboolean,
    ) -> jstring {
        let options = match read_string(&mut env, options_json).and_then(|value| {
            serde_json::from_str::<EmbeddedConversionOptionsV1>(&value).map_err(|e| e.to_string())
        }) {
            Ok(options) => options,
            Err(error) => {
                fail::<()>(format!("Invalid Android conversion options: {error}"));
                return std::ptr::null_mut();
            }
        };
        convert_android(
            env,
            activity,
            path,
            output,
            chapter_start,
            chapter_end,
            streaming != 0,
            Some(options),
        )
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativePrepareConversion(
        env: JNIEnv<'_>,
        worker: JObject<'_>,
        request: JString<'_>,
    ) {
        Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePrepareConversion(
            env, worker, request,
        )
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativeConvertWithOptions(
        env: JNIEnv<'_>,
        worker: JObject<'_>,
        path: JString<'_>,
        output: JString<'_>,
        chapter_start: jint,
        chapter_end: jint,
        options_json: JString<'_>,
        streaming: jboolean,
    ) -> jstring {
        Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvertWithOptions(
            env,
            worker,
            path,
            output,
            chapter_start,
            chapter_end,
            options_json,
            streaming,
        )
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativeCancelConversion(
        mut env: JNIEnv<'_>,
        worker: JObject<'_>,
        request: JString<'_>,
    ) -> jboolean {
        let active = env
            .get_string(&request)
            .ok()
            .map(String::from)
            .is_some_and(|request| {
                android_controls()
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .contains_key(&request)
            });
        Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeCancelConversion(
            env, worker, request,
        );
        active as jboolean
    }

    fn convert_android(
        mut env: JNIEnv<'_>,
        activity: JObject<'_>,
        path: JString<'_>,
        output: JString<'_>,
        chapter_start: jint,
        chapter_end: jint,
        streaming: bool,
        options: Option<EmbeddedConversionOptionsV1>,
    ) -> jstring {
        eprintln!("converter-ffi: nativeConvert entered");
        #[cfg(feature = "piper-runtime")]
        piper_runtime_register_embedded();
        let path = match read_string(&mut env, path) {
            Ok(path) => path,
            Err(_) => return std::ptr::null_mut(),
        };
        let output = match read_string(&mut env, output) {
            Ok(output) => output,
            Err(_) => return std::ptr::null_mut(),
        };
        let request_id = output.clone();
        let control = android_controls()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .entry(request_id.clone())
            .or_default()
            .clone();
        struct RemoveControl(String);
        impl Drop for RemoveControl {
            fn drop(&mut self) {
                android_controls()
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .remove(&self.0);
            }
        }
        let _remove_control = RemoveControl(request_id.clone());
        let input_path = path.clone();
        let path = match CString::new(path) {
            Ok(path) => path,
            Err(_) => return std::ptr::null_mut(),
        };
        let handle = unsafe { converter_session_open(path.as_ptr()) };
        eprintln!("converter-ffi: open returned");
        if handle.is_null() {
            eprintln!("converter-ffi: open failed");
            return std::ptr::null_mut();
        }
        let platform = match env.get_java_vm().and_then(|vm| {
            env.new_global_ref(&activity)
                .map(|activity| AndroidPlatformSpeech {
                    vm,
                    activity,
                    input_path,
                })
        }) {
            Ok(platform) => platform,
            Err(error) => {
                unsafe { converter_session_free(handle) };
                fail::<()>(format!("Android speech adapter unavailable: {error}"));
                return std::ptr::null_mut();
            }
        };
        unsafe {
            (*handle).platform_tts = Some(Arc::new(platform));
        }
        let job = converter_core::embedded::fresh_embedded_job_id();
        let output = match CString::new(Path::new(&output).join(&job).to_string_lossy().as_bytes())
        {
            Ok(output) => output,
            Err(_) => {
                unsafe { converter_session_free(handle) };
                return std::ptr::null_mut();
            }
        };
        let job = CString::new(job).unwrap();
        let chunk_context = if streaming {
            match env.get_java_vm().and_then(|vm| {
                env.new_global_ref(&activity)
                    .map(|activity| AndroidAudioChunks {
                        vm,
                        activity,
                        request_id: request_id.clone(),
                        root: Path::new(&request_id).join("chunks"),
                        control: control.clone(),
                        delivered: std::sync::atomic::AtomicUsize::new(0),
                    })
            }) {
                Ok(context) => Some(context),
                Err(error) => {
                    unsafe { converter_session_free(handle) };
                    fail::<()>(format!("Android audio chunk bridge unavailable: {error}"));
                    return std::ptr::null_mut();
                }
            }
        } else {
            None
        };
        let control = ConverterJobControl {
            control,
            audio_chunks: Default::default(),
        };
        let result = unsafe {
            convert_job_json(
                handle,
                output.as_ptr(),
                job.as_ptr(),
                chapter_start,
                chapter_end,
                None,
                None,
                chunk_context
                    .as_ref()
                    .map_or(std::ptr::null_mut(), |context| {
                        (context as *const AndroidAudioChunks).cast_mut().cast()
                    }),
                Some(control.control.clone()),
                if streaming {
                    Some(android_audio_chunk)
                } else {
                    None
                },
                options.unwrap_or_default(),
            )
        };
        eprintln!(
            "converter-ffi: conversion returned result={}",
            !result.is_null()
        );
        unsafe { converter_session_free(handle) };
        if result.is_null() {
            return std::ptr::null_mut();
        }
        let manifest = unsafe { CStr::from_ptr(result) }
            .to_string_lossy()
            .into_owned();
        unsafe { converter_string_free(result) };
        if let Some(context) = &chunk_context {
            if context.delivered.load(std::sync::atomic::Ordering::Acquire) == 0 {
                let cached = serde_json::from_str::<serde_json::Value>(&manifest)
                    .ok()
                    .and_then(|value| {
                        value
                            .get("audioPath")
                            .and_then(|path| path.as_str())
                            .map(str::to_owned)
                    });
                if let Some(path) = cached {
                    let delivered = std::fs::read(&path).ok().is_some_and(|audio| {
                        context.dispatch(chapter_start.max(0) as usize, 0, &audio)
                    });
                    if !delivered {
                        fail::<()>("Android cached audio delivery was cancelled".into());
                        return std::ptr::null_mut();
                    }
                }
            }
        }
        env.new_string(manifest)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeJobLog(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        job_id: JString<'_>,
    ) -> jstring {
        let job_id = match read_string(&mut env, job_id) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let path = std::env::temp_dir()
            .join("converter-ffi/jobs")
            .join(format!("{job_id}.json"));
        let value = std::fs::read_to_string(path).unwrap_or_else(|_| "[]".to_owned());
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeLastError(
        env: JNIEnv<'_>,
        _class: JClass<'_>,
    ) -> jstring {
        let error = unsafe { converter_last_error() };
        if error.is_null() {
            return env
                .new_string("converter-ffi failed without an error")
                .map_or(std::ptr::null_mut(), |value| value.into_raw());
        }
        let value = unsafe { CStr::from_ptr(error) }
            .to_string_lossy()
            .into_owned();
        unsafe { converter_string_free(error) };
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModels(
        env: JNIEnv<'_>,
        _class: JClass<'_>,
    ) -> jstring {
        let value = serde_json::to_string(converter_core::model_catalog::MODELS)
            .unwrap_or_else(|error| format!("{{\"error\":\"{error}\"}}"));
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsDefaultEngine(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        language: JString<'_>,
        platform: JString<'_>,
        android_api: jint,
    ) -> jstring {
        let language = match read_string(&mut env, language) {
            Ok(value) => value,
            Err(error) => {
                return env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let platform = match read_string(&mut env, platform) {
            Ok(value) => value,
            Err(error) => {
                return env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let platform = match platform.to_ascii_lowercase().as_str() {
            "android" => converter_core::model_catalog::ModelPlatform::Android,
            "ios" => converter_core::model_catalog::ModelPlatform::Ios,
            "macos" => converter_core::model_catalog::ModelPlatform::Macos,
            "linux" => converter_core::model_catalog::ModelPlatform::Linux,
            "windows" => converter_core::model_catalog::ModelPlatform::Windows,
            other => {
                return env
                    .new_string(format!("unsupported platform: {other}"))
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let api = (android_api > 0).then_some(android_api as u32);
        let engine = converter_core::model_catalog::default_engine(&language, platform, api);
        env.new_string(engine)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsInstalledReadyEngine(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        language: JString<'_>,
        platform: JString<'_>,
        android_api: jint,
        installed_json: JString<'_>,
        ready_json: JString<'_>,
    ) -> jstring {
        let values = [language, platform, installed_json, ready_json]
            .into_iter()
            .map(|value| read_string(&mut env, value))
            .collect::<Result<Vec<_>, _>>();
        let values = match values {
            Ok(values) => values,
            Err(error) => {
                return env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let c_values = values
            .iter()
            .map(|value| CString::new(value.as_str()))
            .collect::<Result<Vec<_>, _>>();
        let c_values = match c_values {
            Ok(values) => values,
            Err(_) => return std::ptr::null_mut(),
        };
        let engine = unsafe {
            converter_tts_installed_ready_engine(
                c_values[0].as_ptr(),
                c_values[1].as_ptr(),
                android_api.max(0) as u32,
                c_values[2].as_ptr(),
                c_values[3].as_ptr(),
            )
        };
        if engine.is_null() {
            return std::ptr::null_mut();
        }
        let value = unsafe { CStr::from_ptr(engine) }
            .to_string_lossy()
            .into_owned();
        unsafe { converter_string_free(engine) };
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstall(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        model_id: JString<'_>,
        url: JString<'_>,
        sha256: JString<'_>,
        root: JString<'_>,
    ) -> jstring {
        let values = [model_id, url, sha256, root]
            .into_iter()
            .map(|value| read_string(&mut env, value))
            .collect::<Result<Vec<_>, _>>();
        let values = match values {
            Ok(values) => values,
            Err(error) => {
                return env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let c_values = values
            .iter()
            .map(|value| CString::new(value.as_str()))
            .collect::<Result<Vec<_>, _>>();
        let c_values = match c_values {
            Ok(values) => values,
            Err(_) => return std::ptr::null_mut(),
        };
        let path = unsafe {
            converter_tts_model_install(
                c_values[0].as_ptr(),
                c_values[1].as_ptr(),
                c_values[2].as_ptr(),
                c_values[3].as_ptr(),
            )
        };
        if path.is_null() {
            return std::ptr::null_mut();
        }
        let value = unsafe { CStr::from_ptr(path) }
            .to_string_lossy()
            .into_owned();
        unsafe { converter_string_free(path) };
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallManifest(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        model_id: JString<'_>,
        artifacts_json: JString<'_>,
        root: JString<'_>,
    ) -> jstring {
        let values = [model_id, artifacts_json, root]
            .into_iter()
            .map(|value| read_string(&mut env, value))
            .collect::<Result<Vec<_>, _>>();
        let values = match values {
            Ok(values) => values,
            Err(error) => {
                return env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let c_values = values
            .iter()
            .map(|value| CString::new(value.as_str()))
            .collect::<Result<Vec<_>, _>>();
        let c_values = match c_values {
            Ok(values) => values,
            Err(_) => return std::ptr::null_mut(),
        };
        let path = unsafe {
            converter_tts_model_install_manifest(
                c_values[0].as_ptr(),
                c_values[1].as_ptr(),
                c_values[2].as_ptr(),
            )
        };
        if path.is_null() {
            return std::ptr::null_mut();
        }
        let value = unsafe { CStr::from_ptr(path) }
            .to_string_lossy()
            .into_owned();
        unsafe { converter_string_free(path) };
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallCatalogManifest(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        model_id: JString<'_>,
        root: JString<'_>,
    ) -> jstring {
        let model_id = match read_string(&mut env, model_id) {
            Ok(value) => value,
            Err(error) => {
                return env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let root = match read_string(&mut env, root) {
            Ok(value) => value,
            Err(error) => {
                return env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        };
        let model_id = match CString::new(model_id) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let root = match CString::new(root) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let path = unsafe {
            converter_tts_model_install_catalog_manifest(model_id.as_ptr(), root.as_ptr())
        };
        if path.is_null() {
            return std::ptr::null_mut();
        }
        let value = unsafe { CStr::from_ptr(path) }
            .to_string_lossy()
            .into_owned();
        unsafe { converter_string_free(path) };
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelMetadata(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        model_id: JString<'_>,
        root: JString<'_>,
    ) -> jstring {
        let model_id = match read_string(&mut env, model_id) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let root = match read_string(&mut env, root) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let model_id = match CString::new(model_id) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let root = match CString::new(root) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let metadata = unsafe { converter_tts_model_metadata(model_id.as_ptr(), root.as_ptr()) };
        if metadata.is_null() {
            return std::ptr::null_mut();
        }
        let value = unsafe { CStr::from_ptr(metadata) }
            .to_string_lossy()
            .into_owned();
        unsafe { converter_string_free(metadata) };
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    }

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelRemove(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        model_id: JString<'_>,
        root: JString<'_>,
    ) -> jboolean {
        let model_id = match read_string(&mut env, model_id) {
            Ok(value) => value,
            Err(_) => return 0,
        };
        let root = match read_string(&mut env, root) {
            Ok(value) => value,
            Err(_) => return 0,
        };
        let model_id = match CString::new(model_id) {
            Ok(value) => value,
            Err(_) => return 0,
        };
        let root = match CString::new(root) {
            Ok(value) => value,
            Err(_) => return 0,
        };
        unsafe { converter_tts_model_remove(model_id.as_ptr(), root.as_ptr()) as jboolean }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{ffi::CString, io::Write, ptr};
    use zip::{write::FileOptions, ZipWriter};

    unsafe extern "C" fn platform_test_speech(
        text: *const c_char,
        language: *const c_char,
        output: *const c_char,
        cancelled: ConverterPlatformCancelled,
        cancel_context: *const c_void,
        _error: *mut c_char,
        _error_length: u32,
        context: *mut c_void,
    ) -> bool {
        if cancelled(cancel_context) {
            return false;
        }
        assert!(!CStr::from_ptr(text).to_bytes().is_empty());
        assert_eq!(CStr::from_ptr(language).to_str().unwrap(), "pt-BR");
        let calls = &*context.cast::<std::sync::atomic::AtomicUsize>();
        calls.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let rate = 22_050u32;
        let pcm: Vec<u8> = (0..rate)
            .flat_map(|i| {
                let phase = i as f32 * 440.0 * std::f32::consts::TAU / rate as f32;
                ((phase.sin() * 8_000.0) as i16).to_le_bytes()
            })
            .collect();
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&rate.to_le_bytes());
        wav.extend_from_slice(&(rate * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        wav.extend_from_slice(&pcm);
        std::fs::write(CStr::from_ptr(output).to_str().unwrap(), wav).is_ok()
    }

    #[test]
    fn typed_preferences_are_authoritative_and_online_fallback_is_explicit() {
        let options = CString::new(r#"{"engine":"piper","tts_preferences":{"primary":{"engine":"edge","model_id":null,"voice":"pt-BR-FranciscaNeural"},"secondary":null,"allow_online_fallback":false}}"#).unwrap();
        assert!(unsafe { converter_conversion_options_validate_json_v1(options.as_ptr()) });
        let denied = CString::new(r#"{"tts_preferences":{"primary":{"engine":"piper","model_id":"pt_BR-faber-medium","voice":null},"secondary":{"engine":"edge","model_id":null,"voice":null},"allow_online_fallback":false}}"#).unwrap();
        assert!(!unsafe { converter_conversion_options_validate_json_v1(denied.as_ptr()) });
        let invalid = CString::new(r#"{"engine":"invented"}"#).unwrap();
        assert!(!unsafe { converter_conversion_options_validate_json_v1(invalid.as_ptr()) });
    }

    #[test]
    fn platform_callback_synthesizes_a_validated_job_without_network_or_piper() {
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(root.path().join("system-job").to_str().unwrap()).unwrap();
        let job = CString::new("system-job").unwrap();
        let options = CString::new(r#"{"engine":"system","language":"pt-BR"}"#).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast(),
            ));
            let response = converter_session_convert_job_options_json_v1(
                session,
                output.as_ptr(),
                job.as_ptr(),
                options.as_ptr(),
                0,
                0,
                None,
                None,
                ptr::null_mut(),
            );
            if response.is_null() {
                let error = converter_last_error();
                let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                converter_string_free(error);
                converter_session_free(session);
                panic!("{message}");
            }
            let value: serde_json::Value =
                serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            assert_eq!(value["systemVoiceUsed"], true);
            assert_eq!(value["manifest"]["chapters"].as_array().unwrap().len(), 1);
            let path = value["audioPath"].as_str().unwrap();
            converter_core::audio::validate_audio(Path::new(path), 1).unwrap();
            assert!(calls.load(std::sync::atomic::Ordering::Relaxed) > 0);
            converter_string_free(response);
            assert!(converter_session_set_platform_tts_v1(
                session,
                None,
                ptr::null_mut()
            ));
            assert!((*session).platform_tts.is_none());
            converter_session_free(session);
        }
    }

    #[test]
    fn platform_callback_rejects_null_session_and_borrows_cancellation() {
        unsafe {
            assert!(!converter_session_set_platform_tts_v1(
                ptr::null_mut(),
                None,
                ptr::null_mut()
            ));
            let cancelled = || true;
            let context = PlatformCancellation {
                cancelled: &cancelled,
            };
            assert!(platform_cancelled(
                (&context as *const PlatformCancellation<'_>).cast()
            ));
            assert!(platform_cancelled(ptr::null()));
        }
    }

    #[test]
    fn embedded_engine_defaults_to_edge_and_requires_explicit_piper_selection() {
        assert_eq!(embedded_engine_from_value(None), "edge");
        assert_eq!(embedded_engine_from_value(Some("")), "edge");
        assert_eq!(embedded_engine_from_value(Some("invalid")), "edge");
        assert_eq!(embedded_engine_from_value(Some("piper")), "piper");
        assert_eq!(embedded_engine_from_value(Some(" Piper ")), "piper");
    }

    #[test]
    fn piper_requires_an_installed_model_and_voice_config() {
        let root = tempfile::tempdir().unwrap();
        let model_dir = root.path().join("pt_BR-edresson-low");
        std::fs::create_dir_all(&model_dir).unwrap();
        let model = model_dir.join("model.onnx");
        std::fs::write(&model, b"fixture").unwrap();
        let options = EmbeddedConversionOptionsV1 {
            engine: Some("piper".to_owned()),
            models_root: Some(root.path().to_string_lossy().into_owned()),
            model_id: Some("pt_BR-edresson-low".to_owned()),
            ..EmbeddedConversionOptionsV1::default()
        };
        assert!(resolve_piper_model_paths(&options).is_err());
        let config = model_dir.join("model.onnx.json");
        std::fs::write(&config, b"{}").unwrap();
        assert_eq!(
            resolve_piper_model_paths(&options).unwrap(),
            (model, config)
        );
    }

    fn fixture() -> tempfile::NamedTempFile {
        fixture_chapters(1)
    }

    #[test]
    fn legacy_conversion_failures_keep_independent_default_job_identity() {
        const GUARD: &str = "EPUB_LEGACY_JOB_IDENTITY_ISOLATED_TEST";
        if std::env::var(GUARD).as_deref() != Ok("1") {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "tests::legacy_conversion_failures_keep_independent_default_job_identity",
                    "--nocapture",
                    "--test-threads=1",
                ])
                .env(GUARD, "1")
                .env("PATH", "/no-tools")
                .env("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1")
                .env("EDGE_PROXY", "blocked://no-network")
                .env("NO_PROXY", "")
                .env("no_proxy", "")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(String::from_utf8_lossy(&output.stdout)
                .contains("LEGACY_JOB_IDENTITY_ASSERTIONS_COMPLETED"));
            return;
        }
        struct SessionGuard(*mut ConverterSession);
        impl Drop for SessionGuard {
            fn drop(&mut self) {
                unsafe { converter_session_free(self.0) };
            }
        }
        let book = fixture();
        let source = std::fs::read(book.path()).unwrap();
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(root.path().to_str().unwrap()).unwrap();
        let session = SessionGuard(unsafe { converter_session_open(input.as_ptr()) });
        assert!(!session.0.is_null());
        let mut errors = Vec::new();
        for _ in 0..2 {
            unsafe {
                let response =
                    converter_session_convert_json(session.0, output.as_ptr(), i32::MAX, i32::MAX);
                if !response.is_null() {
                    converter_string_free(response);
                    panic!("an absent chapter must fail before synthesis");
                }
                let error = converter_last_error();
                assert!(!error.is_null());
                errors.push(CStr::from_ptr(error).to_string_lossy().into_owned());
                converter_string_free(error);
            }
        }
        assert!(
            errors.iter().all(|error| error.contains("selected chapters have no readable text")),
            "each fresh legacy call must reach chapter validation without an ID collision: {errors:?}"
        );
        let jobs = converter_core::jobs::JobManager::new(root.path().join(".jobs"))
            .unwrap()
            .list()
            .unwrap();
        assert_eq!(jobs.len(), 2);
        assert_ne!(jobs[0].job_id, jobs[1].job_id);
        assert!(jobs
            .iter()
            .all(|job| job.state == converter_core::jobs::JobState::Failed));
        assert_eq!(std::fs::read(book.path()).unwrap(), source);
        println!("LEGACY_JOB_IDENTITY_ASSERTIONS_COMPLETED");
    }

    fn fixture_chapters(count: usize) -> tempfile::NamedTempFile {
        fixture_chapters_with_text(count, "Hello world.")
    }

    fn fixture_chapters_with_text(count: usize, text: &str) -> tempfile::NamedTempFile {
        let file = tempfile::Builder::new()
            .suffix(".epub")
            .tempfile()
            .expect("temporary EPUB");
        let mut zip = ZipWriter::new(file.reopen().expect("reopen fixture"));
        let options = FileOptions::<()>::default();
        zip.start_file("META-INF/container.xml", options).unwrap();
        zip.write_all(br#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#).unwrap();
        zip.start_file("OEBPS/content.opf", options).unwrap();
        let manifest = (0..count).map(|index| format!(r#"<item id="chapter{index}" href="chapter{index}.xhtml" media-type="application/xhtml+xml"/>"#)).collect::<String>();
        let spine = (0..count)
            .map(|index| format!(r#"<itemref idref="chapter{index}"/>"#))
            .collect::<String>();
        let package = format!(
            r#"<package xmlns:dc="x"><metadata><title>Test Book</title><creator>Author</creator><language>en</language></metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>"#
        );
        zip.write_all(package.as_bytes()).unwrap();
        for index in 0..count {
            zip.start_file(format!("OEBPS/chapter{index}.xhtml"), options)
                .unwrap();
            zip.write_all(
                format!("<html><body><h1>Chapter {index}</h1><p>{text}</p></body></html>")
                    .as_bytes(),
            )
            .unwrap();
        }
        zip.finish().unwrap();
        file
    }

    struct ControlCallbackFixture {
        handle: *mut ConverterJobControl,
        chapters: Vec<usize>,
        cancel_on_first: bool,
        freed: bool,
        recovery_rejected: bool,
    }

    unsafe extern "C" fn controlled_chapter_callback(json: *const c_char, context: *mut c_void) {
        let fixture = &mut *(context as *mut ControlCallbackFixture);
        let event = CStr::from_ptr(json).to_bytes();
        if let Ok(event) = serde_json::from_slice::<serde_json::Value>(event) {
            if let Some(index) = event["chapterIndex"].as_u64() {
                fixture.chapters.push(index as usize);
            }
        }
        if !fixture.freed {
            let late_source = CString::new("late-predecessor").unwrap();
            fixture.recovery_rejected =
                !converter_job_control_set_recovery_job(fixture.handle, late_source.as_ptr());
            if fixture.cancel_on_first {
                converter_job_control_cancel(fixture.handle);
            }
            converter_job_control_free(fixture.handle);
            fixture.handle = ptr::null_mut();
            fixture.freed = true;
        }
    }

    #[test]
    fn controlled_ffi_rejects_null_control_and_keeps_null_cleanup_safe() {
        unsafe {
            converter_job_control_free(ptr::null_mut());
            converter_job_control_cancel(ptr::null());
            converter_job_control_set_paused(ptr::null(), true);
            converter_job_control_set_paused(ptr::null(), false);
            assert!(!converter_job_control_chapter_is_in_playback_window(
                ptr::null(),
                0
            ));
            assert!(!converter_job_control_prioritize(ptr::null(), 0));
            assert!(!converter_job_control_set_recovery_job(
                ptr::null(),
                ptr::null()
            ));
            assert!(converter_session_convert_controlled_job_json(
                ptr::null(),
                ptr::null(),
                ptr::null(),
                0,
                -1,
                None,
                None,
                ptr::null_mut(),
                ptr::null()
            )
            .is_null());
            let error = converter_last_error();
            assert_eq!(
                CStr::from_ptr(error).to_str().unwrap(),
                "invalid null job control"
            );
            converter_string_free(error);
        }
    }

    #[test]
    fn playback_window_query_tracks_runtime_navigation() {
        unsafe {
            let control = converter_job_control_create();
            assert!(!control.is_null());
            converter_job_control_set_playback_window(control, 3, 1);
            assert!(converter_job_control_chapter_is_in_playback_window(
                control, 3
            ));
            assert!(converter_job_control_chapter_is_in_playback_window(
                control, 4
            ));
            assert!(!converter_job_control_chapter_is_in_playback_window(
                control, 2
            ));

            converter_job_control_set_playback_window(control, 7, 1);
            assert!(!converter_job_control_chapter_is_in_playback_window(
                control, 3
            ));
            assert!(converter_job_control_chapter_is_in_playback_window(
                control, 7
            ));
            converter_job_control_free(control);
        }
    }

    #[test]
    fn controlled_ffi_recovery_copies_caller_string_without_mutating_another_handle() {
        unsafe {
            let predecessor = converter_job_control_create();
            let successor = converter_job_control_create();
            let job_id = CString::new("retained-predecessor").unwrap();
            assert!(converter_job_control_set_recovery_job(
                successor,
                job_id.as_ptr()
            ));
            drop(job_id);
            assert_eq!(
                (*successor).control.recover_job().as_deref(),
                Some("retained-predecessor")
            );
            assert_eq!((*predecessor).control.recover_job(), None);
            assert!(!converter_job_control_set_recovery_job(
                successor,
                ptr::null()
            ));
            for invalid in ["", ".", "..", "../foreign", "a/b", "a\\b"] {
                let invalid = CString::new(invalid).unwrap();
                assert!(!converter_job_control_set_recovery_job(
                    successor,
                    invalid.as_ptr()
                ));
            }
            assert_eq!(
                (*successor).control.recover_job().as_deref(),
                Some("retained-predecessor"),
                "Rejected replacement must preserve the accepted recovery intent"
            );
            converter_job_control_free(successor);
            converter_job_control_free(predecessor);
        }
    }

    unsafe extern "C" fn queued_test_speech(
        text: *const c_char,
        language: *const c_char,
        output: *const c_char,
        cancelled: ConverterPlatformCancelled,
        cancel_context: *const c_void,
        error: *mut c_char,
        error_length: u32,
        context: *mut c_void,
    ) -> bool {
        let calls = &*context.cast::<std::sync::atomic::AtomicUsize>();
        if calls.load(std::sync::atomic::Ordering::Acquire) > 0 {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            while !cancelled(cancel_context) && std::time::Instant::now() < deadline {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            return false;
        }
        platform_test_speech(
            text,
            language,
            output,
            cancelled,
            cancel_context,
            error,
            error_length,
            context,
        )
    }

    #[test]
    fn queued_streaming_publishes_a_real_segment_before_chapter_completion_and_cancels() {
        let book =
            fixture_chapters_with_text(1, &"A long sentence for progressive audio. ".repeat(80));
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("queued-stream");
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(directory.to_str().unwrap()).unwrap();
        let job = CString::new("queued-stream").unwrap();
        let options = CString::new(r#"{"language":"pt-BR","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null}}}"#).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(queued_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast()
            ));
            let control = converter_job_control_create();
            assert!(converter_job_control_enable_audio_chunks(control));
            let session_address = session as usize;
            let control_address = control as usize;
            std::thread::scope(|scope| {
                let worker = scope.spawn(move || {
                    let result = converter_session_convert_streaming_job_options_json_v1(
                        session_address as *const ConverterSession,
                        output.as_ptr(),
                        job.as_ptr(),
                        options.as_ptr(),
                        0,
                        0,
                        None,
                        None,
                        None,
                        ptr::null_mut(),
                        control_address as *const ConverterJobControl,
                    );
                    let cancelled = result.is_null();
                    converter_string_free(result);
                    cancelled
                });
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
                let event = loop {
                    let event = converter_job_control_take_audio_chunk_json(control);
                    if !event.is_null() {
                        break event;
                    }
                    assert!(
                        std::time::Instant::now() < deadline,
                        "first playable segment must arrive while conversion runs"
                    );
                    std::thread::sleep(std::time::Duration::from_millis(5));
                };
                let value: serde_json::Value =
                    serde_json::from_str(CStr::from_ptr(event).to_str().unwrap()).unwrap();
                converter_string_free(event);
                assert_eq!(value["chapterIndex"], 0);
                assert_eq!(value["chunkIndex"], 0);
                let path = Path::new(value["path"].as_str().unwrap());
                assert!(path.starts_with(directory.join(".streaming")));
                converter_core::pcm::validate_mp3(&std::fs::read(path).unwrap()).unwrap();
                assert!(!directory.join("manifest.json").exists());
                assert!(!worker.is_finished());
                converter_job_control_cancel(control);
                assert!(worker.join().unwrap());
            });
            assert!(converter_job_control_take_audio_chunk_json(control).is_null());
            assert!(!directory.join("manifest.json").exists());
            assert_eq!(
                std::fs::read_dir(directory.join(".streaming"))
                    .unwrap()
                    .count(),
                1
            );
            assert_eq!(calls.load(std::sync::atomic::Ordering::Acquire), 1);
            converter_session_free(session);
            converter_job_control_free(control);
        }
    }

    #[test]
    fn opaque_tts_policy_state_rejects_invalid_or_exhausted_counters() {
        for failures in [0, 1, 2] {
            let options =
                format!(r#"{{"tts_policy_state":{{"consecutive_failures":{failures}}}}}"#);
            assert!(serde_json::from_str::<EmbeddedConversionOptionsV1>(&options).is_ok());
        }
        for state in [
            r#"{"consecutive_failures":3}"#,
            r#"{"consecutive_failures":-1}"#,
            r#"{"other":0}"#,
            r#""invalid""#,
        ] {
            let options = format!(r#"{{"tts_policy_state":{state}}}"#);
            assert!(serde_json::from_str::<EmbeddedConversionOptionsV1>(&options).is_err());
        }
    }
    #[test]
    fn incompatible_book_language_preflight_only_allows_versioned_native_continuation() {
        let root = tempfile::tempdir().unwrap();
        let mut preferences = converter_core::tts_preferences::TtsPreferences::app_default(true);
        let mut options = serde_json::json!({
            "language": "en",
            "models_root": root.path(),
            "tts_preferences": preferences,
        });
        let validate = |options: &serde_json::Value| {
            let json = CString::new(options.to_string()).unwrap();
            unsafe { converter_conversion_options_validate_json_v1(json.as_ptr()) }
        };
        assert!(validate(&options));
        assert!(root.path().read_dir().unwrap().next().is_none());
        preferences.policy_version = None;
        options["tts_preferences"] = serde_json::to_value(&preferences).unwrap();
        assert!(!validate(&options));
        preferences.policy_version = Some(2);
        preferences.secondary = None;
        options["tts_preferences"] = serde_json::to_value(&preferences).unwrap();
        assert!(!validate(&options));
    }
    #[test]
    fn missing_model_preflight_only_allows_versioned_native_continuation() {
        let root = tempfile::tempdir().unwrap();
        let mut options = EmbeddedConversionOptionsV1 {
            models_root: Some(root.path().to_string_lossy().into_owned()),
            model_id: Some(converter_core::tts_preferences::FABER_MODEL_ID.into()),
            tts_preferences: Some(
                converter_core::tts_preferences::TtsPreferences::app_default(true),
            ),
            ..Default::default()
        };
        let (model, config) = resolve_piper_model_paths(&options).unwrap();
        assert!(!model.exists());
        assert!(!config.exists());
        options.models_root = None;
        assert!(resolve_piper_model_paths(&options).is_ok());
        options.tts_preferences.as_mut().unwrap().policy_version = None;
        assert!(resolve_piper_model_paths(&options).is_err());
        options.tts_preferences.as_mut().unwrap().policy_version = Some(2);
        options.model_path = Some("../escape.onnx".into());
        assert!(resolve_piper_model_paths(&options).is_err());
    }

    #[test]
    fn versioned_missing_piper_converts_through_registered_native_callback() {
        let book = fixture_chapters_with_text(1, &"Uma frase com ação e coração. ".repeat(100));
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(root.path().join("fallback-job").to_str().unwrap()).unwrap();
        let job = CString::new("fallback-job").unwrap();
        let options = CString::new(serde_json::json!({
            "language":"pt-BR",
            "tts_preferences": converter_core::tts_preferences::TtsPreferences::app_default(true)
        }).to_string()).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            assert!(converter_conversion_options_validate_json_v1(
                options.as_ptr()
            ));
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast()
            ));
            let control = converter_job_control_create();
            let response = converter_session_convert_controlled_job_options_json_v1(
                session,
                output.as_ptr(),
                job.as_ptr(),
                options.as_ptr(),
                0,
                0,
                None,
                None,
                ptr::null_mut(),
                control,
            );
            if response.is_null() {
                let error = converter_last_error();
                let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                converter_string_free(error);
                panic!("versioned native fallback failed: {message}");
            }
            let value: serde_json::Value =
                serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            converter_string_free(response);
            assert!(calls.load(std::sync::atomic::Ordering::Acquire) > 3);
            assert_eq!(value["manifest"]["fallbackUsed"], true);
            assert_eq!(value["manifest"]["usedSelections"][0]["engine"], "system");
            converter_session_free(session);
            converter_job_control_free(control);
        }
    }

    #[test]
    fn controlled_typed_options_honor_voice_and_cancel_after_first_real_chapter() {
        let book = fixture_chapters(3);
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("typed-controlled-job");
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(directory.to_str().unwrap()).unwrap();
        let job = CString::new("typed-controlled-job").unwrap();
        // Conflicting legacy engine proves that immutable typed options win.
        let options = CString::new(r#"{"engine":"edge","language":"pt-BR","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null},"secondary":null,"allow_online_fallback":false}}"#).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast()
            ));
            let control = converter_job_control_create();
            assert!(converter_job_control_prioritize(control, 2));
            let mut fixture = ControlCallbackFixture {
                handle: control,
                chapters: Vec::new(),
                cancel_on_first: true,
                freed: false,
                recovery_rejected: false,
            };
            let response = converter_session_convert_controlled_job_options_json_v1(
                session,
                output.as_ptr(),
                job.as_ptr(),
                options.as_ptr(),
                0,
                -1,
                None,
                Some(controlled_chapter_callback),
                (&mut fixture as *mut ControlCallbackFixture).cast(),
                control,
            );
            assert!(response.is_null());
            let error = converter_last_error();
            assert!(!error.is_null());
            let message = CStr::from_ptr(error).to_string_lossy().into_owned();
            converter_string_free(error);
            assert!(message.contains("cancelled"), "{message}");
            assert_eq!(fixture.chapters, [2]);
            assert!(fixture.freed);
            assert!(calls.load(std::sync::atomic::Ordering::Acquire) > 0);
            assert!(!directory.join("manifest.json").exists());
            let completed: Vec<_> = std::fs::read_dir(&directory)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry.path().extension().is_some_and(|value| value == "mp3"))
                .collect();
            assert_eq!(
                completed.len(),
                1,
                "Cancellation must prevent synthesis of later chapters"
            );
            let jobs = converter_core::jobs::JobManager::new(root.path().join(".jobs"))
                .unwrap()
                .list()
                .unwrap();
            assert_eq!(jobs.len(), 1);
            assert_eq!(
                jobs[0].metadata["tts_preferences"]["primary"]["engine"],
                "system"
            );
            converter_session_free(session);
        }
    }

    #[test]
    fn controlled_ffi_recovery_preserves_explicit_zero_and_nonzero_policy_without_synthesis() {
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast(),
            ));
            let convert = |job: &str, predecessor: Option<&str>, failures: usize| {
                let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
                let job = CString::new(job).unwrap();
                let options = CString::new(
                    serde_json::json!({
                        "language": "pt-BR",
                        "tts_preferences": {
                            "primary": {"engine":"system", "model_id":null, "voice":null},
                            "secondary": null, "allow_online_fallback": false
                        },
                        "tts_policy_state": {"consecutive_failures": failures}
                    })
                    .to_string(),
                )
                .unwrap();
                let control = converter_job_control_create();
                assert!(!control.is_null());
                if let Some(predecessor) = predecessor {
                    let source = CString::new(predecessor).unwrap();
                    assert!(converter_job_control_set_recovery_job(
                        control,
                        source.as_ptr()
                    ));
                }
                let response = converter_session_convert_controlled_job_options_json_v1(
                    session,
                    output.as_ptr(),
                    job.as_ptr(),
                    options.as_ptr(),
                    0,
                    0,
                    None,
                    None,
                    ptr::null_mut(),
                    control,
                );
                converter_job_control_free(control);
                if response.is_null() {
                    let error = converter_last_error();
                    let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                    converter_string_free(error);
                    panic!("actual policy recovery failed: {message}");
                }
                let result: serde_json::Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                converter_string_free(response);
                result
            };
            let original = convert("policy-predecessor", None, 2);
            let original_calls = calls.load(std::sync::atomic::Ordering::Acquire);
            assert!(original_calls > 0);
            assert_eq!(
                original["manifest"]["ttsPolicyState"]["consecutive_failures"],
                0
            );
            let original_audio = Path::new(original["audioPath"].as_str().unwrap());
            let audio_bytes = std::fs::read(original_audio).unwrap();
            let receipt_path = original_audio.with_extension("mp3.complete.json");
            let receipt_bytes = std::fs::read(&receipt_path).unwrap();
            let state_path = root.path().join(".jobs/policy-predecessor.json");
            let predecessor_state = std::fs::read(&state_path).unwrap();
            for failures in [0, 2] {
                let job = format!("policy-recovered-{failures}");
                let recovered = convert(&job, Some("policy-predecessor"), failures);
                assert_eq!(
                    calls.load(std::sync::atomic::Ordering::Acquire),
                    original_calls
                );
                assert_eq!(
                    recovered["manifest"]["ttsPolicyState"]["consecutive_failures"],
                    failures
                );
                assert_eq!(
                    recovered["manifest"]["usedSelections"],
                    original["manifest"]["usedSelections"]
                );
                assert_eq!(
                    recovered["manifest"]["fallbackUsed"],
                    original["manifest"]["fallbackUsed"]
                );
                let persisted: serde_json::Value = serde_json::from_slice(
                    &std::fs::read(root.path().join(&job).join("manifest.json")).unwrap(),
                )
                .unwrap();
                assert_eq!(
                    persisted["ttsPolicyState"]["consecutive_failures"],
                    failures
                );
                let recovered_audio = Path::new(recovered["audioPath"].as_str().unwrap());
                assert_eq!(std::fs::read(recovered_audio).unwrap(), audio_bytes);
                assert_eq!(
                    std::fs::read(recovered_audio.with_extension("mp3.complete.json")).unwrap(),
                    receipt_bytes
                );
            }
            assert_eq!(std::fs::read(original_audio).unwrap(), audio_bytes);
            assert_eq!(std::fs::read(receipt_path).unwrap(), receipt_bytes);
            assert_eq!(std::fs::read(state_path).unwrap(), predecessor_state);
            converter_session_free(session);
        }
    }

    #[test]
    fn controlled_ffi_recovery_reuses_validated_predecessor_without_synthesis() {
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let options = CString::new(r#"{"language":"pt-BR","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null},"secondary":null,"allow_online_fallback":false}}"#).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast(),
            ));
            let convert = |job: &str, predecessor: Option<&str>| {
                let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
                let job = CString::new(job).unwrap();
                let control = converter_job_control_create();
                assert!(!control.is_null());
                if let Some(predecessor) = predecessor {
                    let source = CString::new(predecessor).unwrap();
                    assert!(converter_job_control_set_recovery_job(
                        control,
                        source.as_ptr()
                    ));
                }
                let response = converter_session_convert_controlled_job_options_json_v1(
                    session,
                    output.as_ptr(),
                    job.as_ptr(),
                    options.as_ptr(),
                    0,
                    0,
                    None,
                    None,
                    ptr::null_mut(),
                    control,
                );
                converter_job_control_free(control);
                if response.is_null() {
                    let error = converter_last_error();
                    let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                    converter_string_free(error);
                    panic!("actual recovery conversion failed: {message}");
                }
                let manifest: serde_json::Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                converter_string_free(response);
                manifest
            };
            let original = convert("recovery-predecessor", None);
            let original_calls = calls.load(std::sync::atomic::Ordering::Acquire);
            assert!(
                original_calls > 0,
                "Predecessor must synthesize through the actual FFI provider"
            );
            assert!(!original["manifest"]["usedSelections"]
                .as_array()
                .unwrap()
                .is_empty());
            let original_audio = Path::new(original["audioPath"].as_str().unwrap());
            let original_bytes = std::fs::read(original_audio).unwrap();
            converter_core::pcm::validate_mp3(&original_bytes).unwrap();
            let original_receipt_path = original_audio.with_extension("mp3.complete.json");
            let original_receipt = std::fs::read(&original_receipt_path).unwrap();
            let original_manifest =
                std::fs::read(root.path().join("recovery-predecessor/manifest.json")).unwrap();
            let original_state =
                std::fs::read(root.path().join(".jobs/recovery-predecessor.json")).unwrap();

            let recovered = convert("recovery-successor", Some("recovery-predecessor"));
            converter_session_free(session);
            assert_eq!(
                calls.load(std::sync::atomic::Ordering::Acquire),
                original_calls,
                "A matching durable predecessor must avoid synthesizing its completed chapter again",
            );
            assert_eq!(recovered["manifest"]["jobId"], "recovery-successor");
            let recovered_audio = Path::new(recovered["audioPath"].as_str().unwrap());
            assert!(recovered_audio.starts_with(root.path().join("recovery-successor")));
            assert_eq!(std::fs::read(recovered_audio).unwrap(), original_bytes);
            assert_eq!(
                std::fs::read(recovered_audio.with_extension("mp3.complete.json")).unwrap(),
                original_receipt
            );
            assert_eq!(
                recovered["manifest"]["usedSelections"],
                original["manifest"]["usedSelections"]
            );
            assert_eq!(
                recovered["manifest"]["fallbackUsed"],
                original["manifest"]["fallbackUsed"]
            );
            assert_eq!(std::fs::read(original_audio).unwrap(), original_bytes);
            assert_eq!(
                std::fs::read(original_receipt_path).unwrap(),
                original_receipt
            );
            assert_eq!(
                std::fs::read(root.path().join("recovery-predecessor/manifest.json")).unwrap(),
                original_manifest
            );
            assert_eq!(
                std::fs::read(root.path().join(".jobs/recovery-predecessor.json")).unwrap(),
                original_state
            );
        }
    }

    #[test]
    fn controlled_ffi_recovery_reuses_a_chapter_after_selection_renumbers_its_filename() {
        let book = fixture_chapters(2);
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let options = CString::new(r#"{"language":"pt-BR","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null},"secondary":null,"allow_online_fallback":false}}"#).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast(),
            ));
            let convert = |job: &str, start: i32| {
                let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
                let job_id = CString::new(job).unwrap();
                let control = converter_job_control_create();
                if start == 1 {
                    let source = CString::new("selection-predecessor").unwrap();
                    assert!(converter_job_control_set_recovery_job(
                        control,
                        source.as_ptr()
                    ));
                }
                let response = converter_session_convert_controlled_job_options_json_v1(
                    session,
                    output.as_ptr(),
                    job_id.as_ptr(),
                    options.as_ptr(),
                    start,
                    1,
                    None,
                    None,
                    ptr::null_mut(),
                    control,
                );
                converter_job_control_free(control);
                if response.is_null() {
                    let error = converter_last_error();
                    let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                    converter_string_free(error);
                    panic!("Selection fixture {job} failed: {message}");
                }
                let value: serde_json::Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                converter_string_free(response);
                value
            };
            let original = convert("selection-predecessor", 0);
            let original_calls = calls.load(std::sync::atomic::Ordering::Acquire);
            assert_eq!(
                original_calls, 2,
                "Both source chapters must really synthesize"
            );
            let chapter = &original["manifest"]["chapters"][1];
            let source_audio = root
                .path()
                .join("selection-predecessor")
                .join(chapter["filename"].as_str().unwrap());
            let source_bytes = std::fs::read(&source_audio).unwrap();
            let source_receipt =
                std::fs::read(source_audio.with_extension("mp3.complete.json")).unwrap();

            let recovered = convert("selection-successor", 1);
            converter_session_free(session);

            assert_eq!(
                calls.load(std::sync::atomic::Ordering::Acquire),
                original_calls,
                "A matching source chapter must survive selection-dependent filename renumbering"
            );
            let destination = Path::new(recovered["audioPath"].as_str().unwrap());
            assert_ne!(destination.file_name(), source_audio.file_name());
            assert_eq!(
                recovered["manifest"]["chapters"].as_array().unwrap().len(),
                1
            );
            assert_eq!(recovered["manifest"]["chapters"][0]["sourceIndex"], 1);
            assert_eq!(std::fs::read(destination).unwrap(), source_bytes);
            assert_eq!(
                std::fs::read(destination.with_extension("mp3.complete.json")).unwrap(),
                source_receipt
            );
        }
    }

    #[test]
    fn controlled_ffi_recovery_does_not_reuse_a_different_source() {
        let book = fixture();
        let changed_book = fixture_chapters_with_text(1, "This is a different source book.");
        let root = tempfile::tempdir().unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let mut predecessor_receipt = Vec::new();
            let mut predecessor_state = Vec::new();
            let mut predecessor_audio = std::path::PathBuf::new();
            let mut predecessor_calls = 0;
            for (job, source) in [
                ("source-predecessor", book.path()),
                ("source-successor", changed_book.path()),
            ] {
                let input = CString::new(source.to_str().unwrap()).unwrap();
                let session = converter_session_open(input.as_ptr());
                assert!(!session.is_null());
                assert!(converter_session_set_platform_tts_v1(
                    session,
                    Some(platform_test_speech),
                    (&calls as *const std::sync::atomic::AtomicUsize)
                        .cast_mut()
                        .cast(),
                ));
                let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
                let job_id = CString::new(job).unwrap();
                let options = CString::new(
                    serde_json::json!({
                        "language": "pt-BR",
                        "tts_preferences": {
                            "primary": {"engine": "system", "model_id": null, "voice": null},
                            "secondary": null, "allow_online_fallback": false
                        }
                    })
                    .to_string(),
                )
                .unwrap();
                let control = converter_job_control_create();
                if job == "source-successor" {
                    let source = CString::new("source-predecessor").unwrap();
                    assert!(converter_job_control_set_recovery_job(
                        control,
                        source.as_ptr()
                    ));
                }
                let response = converter_session_convert_controlled_job_options_json_v1(
                    session,
                    output.as_ptr(),
                    job_id.as_ptr(),
                    options.as_ptr(),
                    0,
                    0,
                    None,
                    None,
                    ptr::null_mut(),
                    control,
                );
                converter_job_control_free(control);
                converter_session_free(session);
                if response.is_null() {
                    let error = converter_last_error();
                    let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                    converter_string_free(error);
                    panic!("Local fixture conversion {job} failed: {message}");
                }
                let value: serde_json::Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                converter_string_free(response);
                let audio = Path::new(value["audioPath"].as_str().unwrap());
                let receipt = std::fs::read(audio.with_extension("mp3.complete.json")).unwrap();
                let metadata: serde_json::Value = serde_json::from_slice(&receipt).unwrap();
                assert_eq!(metadata["used_selections"][0]["engine"], "system");
                if job == "source-predecessor" {
                    predecessor_calls = calls.load(std::sync::atomic::Ordering::Acquire);
                    assert!(predecessor_calls > 0);
                    predecessor_audio = audio.to_path_buf();
                    predecessor_receipt = receipt;
                    predecessor_state =
                        std::fs::read(root.path().join(".jobs/source-predecessor.json")).unwrap();
                } else {
                    assert!(
                        calls.load(std::sync::atomic::Ordering::Acquire) > predecessor_calls,
                        "A different source must synthesize instead of adopting predecessor audio"
                    );
                    let original: serde_json::Value =
                        serde_json::from_slice(&predecessor_receipt).unwrap();
                    assert_ne!(metadata["request_key"], original["request_key"]);
                }
            }
            assert_eq!(
                std::fs::read(predecessor_audio.with_extension("mp3.complete.json")).unwrap(),
                predecessor_receipt
            );
            assert_eq!(
                std::fs::read(root.path().join(".jobs/source-predecessor.json")).unwrap(),
                predecessor_state
            );
        }
    }

    #[test]
    fn controlled_ffi_recovery_resynthesizes_when_predecessor_audio_hash_differs() {
        assert_recovery_resynthesizes_after_tampering(|audio| {
            let receipt = audio.with_extension("mp3.complete.json");
            let original_receipt = std::fs::read(&receipt).unwrap();
            let mut bytes = std::fs::read(audio).unwrap();
            let original_len = bytes.len();
            *bytes
                .last_mut()
                .expect("predecessor contains actual MP3 bytes") ^= 1;
            std::fs::write(audio, &bytes).unwrap();
            assert_eq!(std::fs::metadata(audio).unwrap().len(), original_len as u64);
            assert_eq!(std::fs::read(receipt).unwrap(), original_receipt);
        });
    }

    #[test]
    fn controlled_ffi_recovery_resynthesizes_when_predecessor_receipt_is_corrupt() {
        assert_recovery_resynthesizes_after_tampering(|audio| {
            std::fs::write(
                audio.with_extension("mp3.complete.json"),
                b"corrupt receipt",
            )
            .unwrap();
        });
    }

    #[cfg(unix)]
    #[test]
    fn controlled_ffi_recovery_does_not_follow_a_predecessor_directory_symlink() {
        let outside = tempfile::tempdir().unwrap();
        assert_recovery_resynthesizes_after_tampering(|audio| {
            let directory = audio.parent().unwrap();
            let external = outside.path().join("external-job");
            std::fs::rename(directory, &external).unwrap();
            std::os::unix::fs::symlink(external, directory).unwrap();
        });
    }

    #[cfg(unix)]
    #[test]
    fn controlled_ffi_recovery_does_not_follow_a_predecessor_audio_symlink() {
        let outside = tempfile::tempdir().unwrap();
        assert_recovery_resynthesizes_after_tampering(|audio| {
            let external = outside.path().join("external.mp3");
            std::fs::rename(audio, &external).unwrap();
            std::os::unix::fs::symlink(external, audio).unwrap();
        });
    }

    #[cfg(unix)]
    #[test]
    fn controlled_ffi_recovery_does_not_follow_a_predecessor_receipt_symlink() {
        let outside = tempfile::tempdir().unwrap();
        assert_recovery_resynthesizes_after_tampering(|audio| {
            let receipt = audio.with_extension("mp3.complete.json");
            let external = outside.path().join("external-receipt.json");
            std::fs::rename(&receipt, &external).unwrap();
            std::os::unix::fs::symlink(external, receipt).unwrap();
        });
    }

    fn assert_recovery_resynthesizes_after_tampering(tamper: impl FnOnce(&Path)) {
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let options = CString::new(r#"{"language":"pt-BR","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null},"secondary":null,"allow_online_fallback":false}}"#).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast(),
            ));
            let convert = |job: &str, recover: bool| {
                let output = CString::new(root.path().join(job).to_str().unwrap()).unwrap();
                let job_id = CString::new(job).unwrap();
                let control = converter_job_control_create();
                assert!(!control.is_null());
                if recover {
                    let source = CString::new("tampered-predecessor").unwrap();
                    assert!(converter_job_control_set_recovery_job(
                        control,
                        source.as_ptr()
                    ));
                }
                let response = converter_session_convert_controlled_job_options_json_v1(
                    session,
                    output.as_ptr(),
                    job_id.as_ptr(),
                    options.as_ptr(),
                    0,
                    0,
                    None,
                    None,
                    ptr::null_mut(),
                    control,
                );
                converter_job_control_free(control);
                if response.is_null() {
                    let error = converter_last_error();
                    let message = CStr::from_ptr(error).to_string_lossy().into_owned();
                    converter_string_free(error);
                    panic!("Local tampering fixture {job} failed: {message}");
                }
                let value: serde_json::Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                converter_string_free(response);
                value
            };
            let original = convert("tampered-predecessor", false);
            let original_calls = calls.load(std::sync::atomic::Ordering::Acquire);
            assert!(original_calls > 0);
            let audio = Path::new(original["audioPath"].as_str().unwrap());
            tamper(audio);
            let predecessor_audio = std::fs::read(audio).unwrap();
            let receipt = audio.with_extension("mp3.complete.json");
            let predecessor_receipt = std::fs::read(&receipt).unwrap();
            let job_path = root.path().join(".jobs/tampered-predecessor.json");
            let predecessor_state = std::fs::read(&job_path).unwrap();

            let recovered = convert("tampered-successor", true);
            converter_session_free(session);
            assert!(
                calls.load(std::sync::atomic::Ordering::Acquire) > original_calls,
                "Untrusted predecessor artifacts must fall back to fresh synthesis"
            );
            let recovered_audio = Path::new(recovered["audioPath"].as_str().unwrap());
            assert!(recovered_audio.starts_with(root.path().join("tampered-successor")));
            converter_core::pcm::validate_mp3(&std::fs::read(recovered_audio).unwrap()).unwrap();
            assert_eq!(std::fs::read(audio).unwrap(), predecessor_audio);
            assert_eq!(std::fs::read(receipt).unwrap(), predecessor_receipt);
            assert_eq!(std::fs::read(job_path).unwrap(), predecessor_state);
        }
    }

    #[test]
    fn controlled_ffi_priority_and_handle_release_preserve_the_active_worker() {
        run_cached_controlled_ffi(false);
    }

    #[test]
    fn controlled_ffi_cancellation_stops_after_validated_cached_chapter() {
        run_cached_controlled_ffi(true);
    }

    #[test]
    fn legacy_controlled_ffi_persists_pre_cancelled_job_without_synthesis() {
        let book = fixture();
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("pre-cancelled-job");
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(directory.to_str().unwrap()).unwrap();
        let job_id = CString::new("pre-cancelled-job").unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast(),
            ));
            let control = converter_job_control_create();
            assert!(!control.is_null());
            converter_job_control_cancel(control);
            let response = converter_session_convert_controlled_job_json(
                session,
                output.as_ptr(),
                job_id.as_ptr(),
                0,
                -1,
                None,
                None,
                ptr::null_mut(),
                control,
            );
            assert!(response.is_null());
            let error = converter_last_error();
            let message = CStr::from_ptr(error).to_string_lossy().into_owned();
            converter_string_free(error);
            assert!(message.contains("cancelled"), "actual error: {message}");
            assert_eq!(calls.load(std::sync::atomic::Ordering::Relaxed), 0);
            let job: serde_json::Value = serde_json::from_slice(
                &std::fs::read(root.path().join(".jobs/pre-cancelled-job.json")).unwrap(),
            )
            .unwrap();
            assert_eq!(job["state"], "cancelled");
            assert!(!directory.join("manifest.json").exists());
            converter_job_control_free(control);
            converter_session_free(session);
        }
    }

    fn run_cached_controlled_ffi(cancel_on_first: bool) {
        let book = fixture_chapters(3);
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("controlled-job");
        std::fs::create_dir_all(&directory).unwrap();
        let input = CString::new(book.path().to_str().unwrap()).unwrap();
        let output = CString::new(directory.to_str().unwrap()).unwrap();
        let job_id = CString::new("controlled-job").unwrap();
        let options = CString::new(r#"{"engine":"system","language":"pt-BR"}"#).unwrap();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        unsafe {
            let session = converter_session_open(input.as_ptr());
            assert!(!session.is_null());
            assert!(converter_session_set_platform_tts_v1(
                session,
                Some(platform_test_speech),
                (&calls as *const std::sync::atomic::AtomicUsize)
                    .cast_mut()
                    .cast(),
            ));
            // Populate validated audio and request receipts through the real FFI
            // pipeline. A bare WAV with an MP3 suffix is not a reusable cache.
            let warm = converter_session_convert_job_options_json_v1(
                session,
                output.as_ptr(),
                job_id.as_ptr(),
                options.as_ptr(),
                0,
                -1,
                None,
                None,
                ptr::null_mut(),
            );
            assert!(!warm.is_null(), "offline fixture conversion must succeed");
            converter_string_free(warm);
            assert!(calls.load(std::sync::atomic::Ordering::Relaxed) > 0);
            let cached_audio: Vec<_> = std::fs::read_dir(&directory)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .filter(|path| path.extension() == Some(std::ffi::OsStr::new("mp3")))
                .map(|path| {
                    converter_core::audio::validate_audio(&path, 1).unwrap();
                    let receipt = path.with_extension("mp3.complete.json");
                    let bytes = std::fs::read(&path).unwrap();
                    let receipt_bytes = std::fs::read(&receipt).unwrap();
                    (path, bytes, receipt, receipt_bytes)
                })
                .collect();
            assert_eq!(cached_audio.len(), 3);
            // Retain artifacts while simulating recovery without a job record.
            std::fs::remove_file(root.path().join(".jobs/controlled-job.json")).unwrap();
            calls.store(0, std::sync::atomic::Ordering::Relaxed);
            let control = converter_job_control_create();
            assert!(!control.is_null());
            assert!(converter_job_control_prioritize(control, 2));
            let mut fixture = ControlCallbackFixture {
                handle: control,
                chapters: Vec::new(),
                cancel_on_first,
                freed: false,
                recovery_rejected: false,
            };
            let response = converter_session_convert_streaming_job_options_json_v1(
                session,
                output.as_ptr(),
                job_id.as_ptr(),
                options.as_ptr(),
                0,
                -1,
                None,
                Some(controlled_chapter_callback),
                None,
                &mut fixture as *mut ControlCallbackFixture as *mut c_void,
                control,
            );
            if cancel_on_first {
                assert!(response.is_null());
                let error = converter_last_error();
                let error_text = CStr::from_ptr(error).to_str().unwrap().to_owned();
                converter_string_free(error);
                assert!(
                    error_text.contains("cancelled"),
                    "actual controlled conversion error: {error_text}"
                );
                assert_eq!(fixture.chapters, [2]);
            } else {
                if response.is_null() {
                    let error = converter_last_error();
                    let error_text = CStr::from_ptr(error).to_str().unwrap().to_owned();
                    converter_string_free(error);
                    panic!("actual controlled conversion error: {error_text}");
                }
                assert_eq!(fixture.chapters, [2, 0, 1]);
                converter_string_free(response);
            }
            assert!(
                fixture.freed,
                "The worker must own its control clone after the caller releases the handle"
            );
            assert!(
                fixture.recovery_rejected,
                "Recovery source cannot change after queue attachment"
            );
            assert_eq!(
                calls.load(std::sync::atomic::Ordering::Relaxed),
                0,
                "controlled conversion must reuse verified audio without synthesis"
            );
            for (path, bytes, receipt, receipt_bytes) in cached_audio {
                assert_eq!(std::fs::read(path).unwrap(), bytes);
                assert_eq!(std::fs::read(receipt).unwrap(), receipt_bytes);
            }
            let job: serde_json::Value = serde_json::from_slice(
                &std::fs::read(root.path().join(".jobs/controlled-job.json")).unwrap(),
            )
            .unwrap();
            assert_eq!(
                job["state"],
                if cancel_on_first {
                    "cancelled"
                } else {
                    "completed"
                }
            );
            converter_session_free(session);
        }
    }

    #[test]
    fn embedded_apple_conversion_uses_bounded_two_chapter_parallelism() {
        assert_eq!(
            embedded_chapter_parallelism_cap(),
            if cfg!(target_os = "macos") || cfg!(target_os = "ios") {
                2
            } else {
                1
            }
        );
    }

    #[test]
    fn progress_log_line_contains_wall_and_relative_timing() {
        let started = std::time::Instant::now();
        let previous = std::sync::Mutex::new(started);
        let event = converter_core::worker::ProgressEvent {
            model_id: None,
            voice: None,
            fallback_used: false,
            job_id: "timing-test".into(),
            state: "running".into(),
            chapter_index: Some(3),
            chapters_total: 10,
            chapters_completed: 2,
            percent: 20.0,
            engine: Some("edge".into()),
            message: "converting chapter 4".into(),
        };
        let line = progress_log_line(&event, started, &previous);
        assert!(line.contains("unix_ms="));
        assert!(line.contains("elapsed_ms="));
        assert!(line.contains("since_event_ms="));
        assert!(line.contains("converting chapter 4"));
    }

    #[test]
    fn null_handles_report_errors_and_free_safely() {
        unsafe {
            converter_session_free(ptr::null_mut());
            converter_string_free(ptr::null_mut());
            assert!(converter_session_metadata_json(ptr::null()).is_null());
            let error = converter_last_error();
            assert_eq!(
                CStr::from_ptr(error).to_str().unwrap(),
                "invalid null session handle"
            );
            converter_string_free(error);
        }
    }

    #[test]
    fn invalid_path_reports_error() {
        let path = CString::new("/definitely/missing/book.epub").unwrap();
        unsafe {
            assert!(converter_session_open(path.as_ptr()).is_null());
            let error = converter_last_error();
            assert!(CStr::from_ptr(error)
                .to_str()
                .unwrap()
                .contains("failed to read input"));
            converter_string_free(error);
        }
    }

    #[test]
    fn shared_model_catalog_and_default_engine_are_exposed() {
        unsafe {
            let catalog = converter_tts_models_json();
            assert!(!catalog.is_null());
            let value = CStr::from_ptr(catalog).to_str().unwrap();
            assert!(value.contains("kokoro-82m"));
            converter_string_free(catalog);

            let language = CString::new("pt-BR").unwrap();
            let platform = CString::new("android").unwrap();
            let engine = converter_tts_default_engine(language.as_ptr(), platform.as_ptr(), 28);
            assert_eq!(CStr::from_ptr(engine).to_str().unwrap(), "none");
            converter_string_free(engine);
        }
    }

    #[test]
    fn ready_model_selection_requires_runtime_verified_ids() {
        let language = CString::new("en-US").unwrap();
        let platform = CString::new("macos").unwrap();
        let installed = CString::new(r#"["kokoro-82m"]"#).unwrap();
        let not_ready = CString::new("[]").unwrap();
        let ready = CString::new(r#"["kokoro-82m"]"#).unwrap();
        unsafe {
            let engine = converter_tts_installed_ready_engine(
                language.as_ptr(),
                platform.as_ptr(),
                0,
                installed.as_ptr(),
                not_ready.as_ptr(),
            );
            assert_eq!(CStr::from_ptr(engine).to_str().unwrap(), "none");
            converter_string_free(engine);

            let engine = converter_tts_installed_ready_engine(
                language.as_ptr(),
                platform.as_ptr(),
                0,
                installed.as_ptr(),
                ready.as_ptr(),
            );
            assert_eq!(CStr::from_ptr(engine).to_str().unwrap(), "kokoro");
            converter_string_free(engine);
        }
    }

    #[test]
    fn manifest_rejects_invalid_json_before_network_access() {
        let model = CString::new("kokoro-82m").unwrap();
        let artifacts = CString::new("not-json").unwrap();
        let root = tempfile::tempdir().unwrap();
        let root = CString::new(root.path().to_str().unwrap()).unwrap();
        unsafe {
            assert!(converter_tts_model_install_manifest(
                model.as_ptr(),
                artifacts.as_ptr(),
                root.as_ptr()
            )
            .is_null());
            let error = converter_last_error();
            assert!(CStr::from_ptr(error)
                .to_str()
                .unwrap()
                .contains("invalid model artifacts JSON"));
            converter_string_free(error);
        }
    }

    #[test]
    fn catalog_manifest_rejects_unknown_model_before_network_access() {
        let model = CString::new("missing").unwrap();
        let tempdir = tempfile::tempdir().unwrap();
        let root = CString::new(tempdir.path().to_str().unwrap()).unwrap();
        unsafe {
            assert!(
                converter_tts_model_install_catalog_manifest(model.as_ptr(), root.as_ptr())
                    .is_null()
            );
            let error = converter_last_error();
            assert!(CStr::from_ptr(error)
                .to_str()
                .unwrap()
                .contains("unknown TTS model"));
            converter_string_free(error);
        }
    }

    #[test]
    fn valid_session_returns_metadata_json() {
        let fixture = fixture();
        let path = CString::new(fixture.path().to_str().unwrap()).unwrap();
        unsafe {
            let handle = converter_session_open(path.as_ptr());
            assert!(!handle.is_null());
            let metadata = converter_session_metadata_json(handle);
            let json = CStr::from_ptr(metadata).to_str().unwrap();
            assert!(json.contains("Test Book"));
            assert!(json.contains("chapters"));
            converter_string_free(metadata);
            converter_session_free(handle);
        }
    }
}
