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
    embedded::{EmbeddedBookMetadata, EmbeddedConversionSession},
    paths::resolve_paths_from,
};

use serde::Deserialize;
use serde_json::json;
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    path::Path,
    ptr,
};

/// Opaque session handle owned by the caller.
#[repr(C)]
pub struct ConverterSession {
    session: EmbeddedConversionSession,
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
        Ok(session) => Box::into_raw(Box::new(ConverterSession { session })),
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
    let config = AppConfig::from_paths(resolve_paths_from(
        [("OUTPUT_DIR".to_owned(), output_dir.clone())],
        std::path::PathBuf::from(output_dir.clone()),
    ));
    let output = Path::new(&output_dir);
    if let Err(error) = std::fs::create_dir_all(output) {
        return fail(format!("failed to create output directory: {error}"));
    }
    let job = format!("embedded-{}", std::process::id());
    let generated_output_dir = output.join(&job);
    #[cfg(feature = "piper-runtime")]
    piper_runtime_register_embedded();
    let request = converter_core::worker::ConversionRequest {
        input: session.session.input_path().to_path_buf(),
        job_id: job,
        engine: Some("edge".to_owned()),
        voice: None,
        language: None,
        chapter_indices: if chapter_start >= 0 {
            Some(if chapter_end >= chapter_start {
                (chapter_start..=chapter_end)
                    .map(|index| index.to_string())
                    .collect()
            } else {
                vec![chapter_start.to_string()]
            })
        } else {
            None
        },
        no_parallel: true,
    };
    let worker = match converter_core::worker::ConversionWorker::new(config) {
        Ok(worker) => worker,
        Err(error) => return fail(error.to_string()),
    };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| worker.run(request)));
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
    piper::register_runtime(std::sync::Arc::new(
        converter_core::piper::RegisteredPiperRuntime::new(|_, _| {
            Err(converter_core::piper::PiperError::RuntimeUnavailable(
                "native Piper implementation is not linked".into(),
            ))
        }),
    ));
}

#[cfg(feature = "piper-runtime")]
#[no_mangle]
pub extern "C" fn piper_runtime_register_embedded() {
    piper::register_runtime(std::sync::Arc::new(
        converter_core::piper::RegisteredPiperRuntime::new(|text, output| {
            let model = std::env::var_os("PIPER_MODEL")
                .map(std::path::PathBuf::from)
                .or_else(|| {
                    let root = std::path::Path::new(
                        "/data/user/0/com.pietrocode.epubtomp3.flutter_app/app_flutter/tts-models",
                    );
                    std::fs::read_dir(root).ok()?.flatten().find_map(|entry| {
                        let directory = entry.path();
                        ["model.onnx", "model.bin"]
                            .iter()
                            .map(|name| directory.join(name))
                            .find(|candidate| candidate.is_file())
                    })
                })
                .unwrap_or_else(|| std::path::PathBuf::from("/data/user/0/com.pietrocode.epubtomp3.flutter_app/app_flutter/tts-models/model.onnx"));
            let config = if model.file_name().and_then(|name| name.to_str()) == Some("model.onnx") {
                model.with_file_name("model.onnx.json")
            } else {
                model.with_file_name("model.json")
            };
            if !model.is_file() {
                return Err(converter_core::piper::PiperError::MissingModel(model));
            }
            if !config.is_file() {
                return Err(converter_core::piper::PiperError::MissingConfig(config));
            }
            let model = std::ffi::CString::new(model.to_string_lossy().as_bytes())
                .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
            let config = std::ffi::CString::new(config.to_string_lossy().as_bytes())
                .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
            let text = std::ffi::CString::new(text)
                .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
            let output = std::ffi::CString::new(output.to_string_lossy().as_bytes())
                .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
            let mut error = vec![0_u8; 2048];
            if piper_runtime::piper_runtime_init(
                model.as_ptr(),
                config.as_ptr(),
                error.as_mut_ptr(),
                error.len() as u32,
            ) == 0
            {
                return Err(converter_core::piper::PiperError::Synthesis(c_error(
                    &error,
                )));
            }
            if piper_runtime::piper_synthesize(
                text.as_ptr(),
                output.as_ptr(),
                error.as_mut_ptr(),
                error.len() as u32,
            ) == 0
            {
                return Err(converter_core::piper::PiperError::Synthesis(c_error(
                    &error,
                )));
            }
            Ok(())
        }),
    ));
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

#[cfg(all(target_os = "android", feature = "android-jni"))]
mod android_jni {
    use super::*;
    use jni::{
        objects::{JClass, JString},
        sys::{jboolean, jint, jstring},
        JNIEnv,
    };

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
            let initialized = piper_runtime::piper_runtime_init(model.as_ptr(), config.as_ptr(), error.as_mut_ptr(), error.len() as u32);
            if initialized == 0 {
                let message = unsafe { std::ffi::CStr::from_ptr(error.as_ptr()) }.to_string_lossy().into_owned();
                fail::<jboolean>(message);
                return 0;
            }
            let synthesized = piper_runtime::piper_synthesize(text.as_ptr(), output.as_ptr(), error.as_mut_ptr(), error.len() as u32);
            if synthesized == 0 {
                let message = unsafe { std::ffi::CStr::from_ptr(error.as_ptr()) }.to_string_lossy().into_owned();
                fail::<jboolean>(message);
                return 0;
            }
            return 1;
        }
        #[cfg(not(feature = "piper-runtime"))]
        unsafe { if piper_runtime_init(model.as_ptr(), config.as_ptr()) { if piper_synthesize(text.as_ptr(), output.as_ptr()) { 1 } else { 0 } } else { 0 } }
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

    #[no_mangle]
    pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvert(
        mut env: JNIEnv<'_>,
        _class: JClass<'_>,
        path: JString<'_>,
        output: JString<'_>,
        chapter_start: jint,
        chapter_end: jint,
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
        let output = match CString::new(output) {
            Ok(output) => output,
            Err(_) => return std::ptr::null_mut(),
        };
        let result = unsafe {
            converter_session_convert_json(handle, output.as_ptr(), chapter_start, chapter_end)
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
        env.new_string(manifest)
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

    fn fixture() -> tempfile::NamedTempFile {
        let file = tempfile::NamedTempFile::new().expect("temporary EPUB");
        let mut zip = ZipWriter::new(file.reopen().expect("reopen fixture"));
        let options = FileOptions::<()>::default();
        zip.start_file("META-INF/container.xml", options).unwrap();
        zip.write_all(br#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#).unwrap();
        zip.start_file("OEBPS/content.opf", options).unwrap();
        zip.write_all(br#"<package xmlns:dc="x"><metadata><title>Test Book</title><creator>Author</creator><language>en</language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#).unwrap();
        zip.start_file("OEBPS/chapter.xhtml", options).unwrap();
        zip.write_all(b"<html><body><p>Hello world.</p></body></html>")
            .unwrap();
        zip.finish().unwrap();
        file
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
