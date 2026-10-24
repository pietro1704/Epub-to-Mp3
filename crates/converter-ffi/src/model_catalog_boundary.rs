use super::*;

/// Versioned descriptors; catalog presence does not assert installed/readiness state.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_catalog_json_v2() -> *mut c_char {
    clear_last_error();
    CString::new(converter_core::tts_session::catalog_json()).map_or_else(
        |_| fail("TTS catalog contains an interior NUL byte".into()),
        CString::into_raw,
    )
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
