use super::*;

/// Base languages that have at least one catalog model on the platform, as
/// `{"schema_version":1,"languages":[{"tag":"pt","model_count":3,"popularity_rank":3}]}` (the rank is
/// additive and absent for languages outside the shared popularity list). Pure; no I/O.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_catalog_languages_json_v1(
    platform: *const c_char,
    android_api: u32,
) -> *mut c_char {
    ffi_guard(
        "converter_tts_catalog_languages_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let platform = match c_string(platform, "platform")
                .and_then(|value| crate::model_catalog_boundary::model_platform(&value))
            {
                Ok(value) => value,
                Err(error) => return fail(error),
            };
            let languages = converter_core::model_catalog::catalog_languages(
                platform,
                (android_api > 0).then_some(android_api),
            );
            json_string(&json!({ "schema_version": 1, "languages": languages }))
        },
    )
}

/// Resolves which narration a book language plays with (per-language choice,
/// primary, best installed model, setting-gated system voice, or a missing-model
/// result). Pure; never downloads. See `docs/models-by-language-contract.md`.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_resolve_language_model_json_v1(
    request_json: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_tts_resolve_language_model_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let request: converter_core::language_model_resolution::ResolutionRequest =
                match c_string(request_json, "language model request")
                    .and_then(|text| serde_json::from_str(&text).map_err(|error| error.to_string()))
                {
                    Ok(value) => value,
                    Err(error) => return fail(error),
                };
            if request.schema_version != converter_core::language_model_resolution::SCHEMA_VERSION {
                return fail(format!(
                    "unsupported language model request schema {}",
                    request.schema_version
                ));
            }
            if request.book_language.trim().is_empty() {
                return fail("book_language must not be empty".into());
            }
            json_string(&converter_core::language_model_resolution::resolve(
                &request,
            ))
        },
    )
}

/// The narration plan of one book before any audio: the language decision (user correction, whole-book profile,
/// sampled consensus), the main language's voice (the listener's own book voice first), the voice of each other
/// language of the profile, and what to tell the listener when a voice is missing. Pure; never downloads.
/// The request carries the book's `analysis` and `profile` (from `converter_book_language_json_v1`).
#[no_mangle]
pub unsafe extern "C" fn converter_book_narration_plan_json_v1(
    request_json: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_book_narration_plan_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let request: converter_core::narration_plan::PlanRequest =
                match c_string(request_json, "narration plan request")
                    .and_then(|text| serde_json::from_str(&text).map_err(|error| error.to_string()))
                {
                    Ok(value) => value,
                    Err(error) => return fail(error),
                };
            if request.schema_version != converter_core::narration_plan::SCHEMA_VERSION {
                return fail(format!(
                    "unsupported narration plan request schema {}",
                    request.schema_version
                ));
            }
            json_string(&converter_core::narration_plan::plan(&request))
        },
    )
}

fn json_string<T: serde::Serialize>(value: &T) -> *mut c_char {
    match serde_json::to_string(value) {
        Ok(text) => CString::new(text).map_or_else(
            |_| fail("language model JSON contains an interior NUL byte".into()),
            CString::into_raw,
        ),
        Err(error) => fail(error.to_string()),
    }
}

/// Language analysis of a book file, before any job exists:
/// `{"schema_version":1,"declared":...,"confirmed":...,"languages":[...],
/// "samples_examined":n,"inconclusive_samples":n,"detector":"..."}`. Applies the
/// conversion's sampling and confirmation rule (one inconclusive sample among
/// unanimous ones still confirms). Pure: reads the file, writes nothing. Blocking:
/// call it off the UI thread.
#[no_mangle]
pub unsafe extern "C" fn converter_book_language_json_v1(path: *const c_char) -> *mut c_char {
    ffi_guard(
        "converter_book_language_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let path = match c_string(path, "book path") {
                Ok(value) => std::path::PathBuf::from(value),
                Err(error) => return fail(error),
            };
            // Swift cooperative workers have small stacks; parsing and detection
            // get the same budget as the conversion boundary.
            let analysis = std::thread::Builder::new()
                .name("converter-ffi-book-language".into())
                .stack_size(8 * 1024 * 1024)
                .spawn(move || {
                    converter_core::language::analyze_book_file_with_profile(&path, &|| false)
                })
                .map_err(|error| format!("Failed to start language analysis: {error}"))
                .and_then(|handle| {
                    handle
                        .join()
                        .map_err(|_| "Book language analysis panicked".to_owned())?
                });
            match analysis {
                Ok((analysis, profile)) => {
                    let mut value = match serde_json::to_value(&analysis) {
                        Ok(value) => value,
                        Err(error) => return fail(error.to_string()),
                    };
                    value["schema_version"] = json!(1);
                    // Additive: the whole-book profile (class, languages with their shares).
                    match serde_json::to_value(&profile) {
                        Ok(profile) => value["profile"] = profile,
                        Err(error) => return fail(error.to_string()),
                    }
                    json_string(&value)
                }
                Err(error) => fail(error),
            }
        },
    )
}
