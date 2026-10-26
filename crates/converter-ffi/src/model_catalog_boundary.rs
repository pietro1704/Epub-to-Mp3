use super::*;

fn model_platform(value: &str) -> Result<converter_core::model_catalog::ModelPlatform, String> {
    match value.to_ascii_lowercase().as_str() {
        "android" => Ok(converter_core::model_catalog::ModelPlatform::Android),
        "ios" => Ok(converter_core::model_catalog::ModelPlatform::Ios),
        "macos" => Ok(converter_core::model_catalog::ModelPlatform::Macos),
        "linux" => Ok(converter_core::model_catalog::ModelPlatform::Linux),
        "windows" => Ok(converter_core::model_catalog::ModelPlatform::Windows),
        other => Err(format!("unsupported platform: {other}")),
    }
}

/// Versioned descriptors; catalog presence does not assert installed/readiness state.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_catalog_json_v2() -> *mut c_char {
    clear_last_error();
    CString::new(converter_core::tts_session::catalog_json()).map_or_else(
        |_| fail("TTS catalog contains an interior NUL byte".into()),
        CString::into_raw,
    )
}

/// Returns the Rust-owned v3 speech-model snapshot for one target and model root.
///
/// The call performs offline installed-artifact inspection only. Runtime readiness
/// remains `not_inspected` until a concrete runtime probe supplies typed evidence.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_catalog_json_v3(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
    architecture: *const c_char,
    os_version: *const c_char,
    model_root: *const c_char,
) -> *mut c_char {
    speech_model_catalog_json(
        language,
        platform,
        android_api,
        architecture,
        os_version,
        model_root,
        None,
    )
}

/// Explicit offline model loading. Call off the UI thread; no synthesis or download.
/// The original v3 inspection endpoint retains its read-only/no-runtime-load contract.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_catalog_probe_json_v3(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
    architecture: *const c_char,
    os_version: *const c_char,
    model_root: *const c_char,
    espeak_data_directory: *const c_char,
) -> *mut c_char {
    let directory = match c_string(espeak_data_directory, "eSpeak data directory") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    speech_model_catalog_json(
        language,
        platform,
        android_api,
        architecture,
        os_version,
        model_root,
        Some(&directory),
    )
}

unsafe fn speech_model_catalog_json(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
    architecture: *const c_char,
    os_version: *const c_char,
    model_root: *const c_char,
    probe_directory: Option<&str>,
) -> *mut c_char {
    clear_last_error();
    let language = match c_string(language, "language") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let platform = match c_string(platform, "platform").and_then(|value| model_platform(&value)) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let architecture = match c_string(architecture, "architecture") {
        Ok(value) if !value.trim().is_empty() => value,
        Ok(_) => return fail("architecture must not be empty".into()),
        Err(error) => return fail(error),
    };
    let os_version = match c_string(os_version, "OS version") {
        Ok(value) => (!value.trim().is_empty()).then_some(value),
        Err(error) => return fail(error),
    };
    let model_root = match c_string(model_root, "model root") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let query = converter_core::speech_model_library::CatalogQuery {
        language,
        platform,
        android_api: (android_api > 0).then_some(android_api),
        architecture,
        os_version,
    };
    let store = converter_core::model_store::ModelStore::new(Path::new(&model_root));
    let library = converter_core::speech_model_library::SpeechModelLibrary;
    let result = if let Some(directory) = probe_directory {
        library.snapshot_with_runtime_probe(query, &store, |identity| {
            probe_embedded_model(identity, store.root(), directory)
        })
    } else {
        library.snapshot_with_inspection(query, &store, &[])
    };
    let snapshot = match result {
        Ok(value) => value,
        Err(error) => return fail(error.to_string()),
    };
    match serde_json::to_string(&snapshot) {
        Ok(value) => CString::new(value).map_or_else(
            |_| fail("TTS catalog v3 contains an interior NUL byte".to_owned()),
            CString::into_raw,
        ),
        Err(error) => fail(error.to_string()),
    }
}

fn probe_embedded_model(
    identity: &converter_core::speech_model_library::ModelIdentity,
    root: &Path,
    espeak_directory: &str,
) -> converter_core::speech_model_library::RuntimeReadinessOutcome {
    use converter_core::speech_model_library::{ReadinessFailure, RuntimeReadinessOutcome};
    #[cfg(feature = "piper-runtime")]
    if identity.provider == "piper" {
        let prepared = (|| {
            let root = root.canonicalize().map_err(|error| error.to_string())?;
            super::piper_runtime_boundary::configure_piper_data_directory(Path::new(
                espeak_directory,
            ))?;
            converter_core::piper::PreparedPiperModel::prepare(
                &root,
                &identity.model_id,
                Path::new("model.onnx"),
                Path::new("model.onnx.json"),
                Arc::new(super::piper_runtime_boundary::EmbeddedPiperRuntime),
            )
            .map_err(|error| error.to_string())
        })();
        return match prepared {
            Ok(_) => RuntimeReadinessOutcome::Ready {
                active_runtime_revision: format!("piper-embedded:{}", env!("CARGO_PKG_VERSION")),
            },
            Err(_) => RuntimeReadinessOutcome::Unavailable {
                failure: ReadinessFailure::RuntimeRejected,
            },
        };
    }
    let _ = (identity, root, espeak_directory);
    RuntimeReadinessOutcome::Unavailable {
        failure: ReadinessFailure::RuntimeUnavailable,
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
    let platform = match model_platform(&platform) {
        Ok(value) => value,
        Err(error) => return fail(error),
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
    let platform = match model_platform(&platform) {
        Ok(value) => value,
        Err(error) => return fail(error),
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
