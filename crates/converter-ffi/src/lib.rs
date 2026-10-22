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

#[repr(C)]
pub struct PiperStatus {
    pub runtime_loaded: bool,
    pub model_available: bool,
    pub abi_compatible: bool,
    pub engine_ready: bool,
}

pub type PiperRuntimeStatusC = PiperStatus;

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

mod platform_speech_boundary;
pub use platform_speech_boundary::*;
#[cfg(test)]
use platform_speech_boundary::{platform_cancelled, PlatformCancellation};
mod conversion_options_boundary;
use conversion_options_boundary::embedded_engine_from_value;
use conversion_options_boundary::resolve_piper_model_paths;
use conversion_options_boundary::EmbeddedConversionOptionsV1;
pub use conversion_options_boundary::*;
mod job_control_boundary;
pub use job_control_boundary::*;
mod session_boundary;
pub use session_boundary::*;
mod conversion_callback_boundary;
pub use conversion_callback_boundary::*;
mod conversion_job_execution;
use conversion_job_execution::convert_job_json;
use conversion_job_execution::embedded_chapter_parallelism_cap;
use conversion_job_execution::positional_chapter_selection;
use conversion_job_execution::progress_log_line;
mod ffi_memory_boundary;
pub use ffi_memory_boundary::*;
mod model_catalog_boundary;
pub use model_catalog_boundary::*;
mod model_installation_boundary;
pub use model_installation_boundary::*;
mod piper_runtime_boundary;
pub use piper_runtime_boundary::*;
mod job_snapshot_boundary;
pub use job_snapshot_boundary::*;

#[cfg(any(
    all(target_os = "android", feature = "android-jni"),
    all(test, feature = "android-jni")
))]
mod android_jni;

#[cfg(test)]
#[path = "ffi_contract_tests.rs"]
mod tests;
