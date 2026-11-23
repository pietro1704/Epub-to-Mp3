use super::*;

pub(crate) fn model_platform(
    value: &str,
) -> Result<converter_core::model_catalog::ModelPlatform, String> {
    match value.to_ascii_lowercase().as_str() {
        "android" => Ok(converter_core::model_catalog::ModelPlatform::Android),
        "ios" => Ok(converter_core::model_catalog::ModelPlatform::Ios),
        "macos" => Ok(converter_core::model_catalog::ModelPlatform::Macos),
        "linux" => Ok(converter_core::model_catalog::ModelPlatform::Linux),
        "windows" => Ok(converter_core::model_catalog::ModelPlatform::Windows),
        other => Err(format!("unsupported platform: {other}")),
    }
}

/// Returns the Rust-owned v3 speech-model snapshot for one target and model root.
///
/// The call performs offline installed-artifact inspection only. Runtime readiness
/// remains `not_inspected` until a concrete runtime probe supplies typed evidence.
/// An empty model root requests descriptors only, without filesystem inspection.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_catalog_json_v3(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
    architecture: *const c_char,
    os_version: *const c_char,
    model_root: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_tts_catalog_json_v3",
        std::ptr::null_mut(),
        || {
            speech_model_catalog_json(
                language,
                platform,
                android_api,
                architecture,
                os_version,
                model_root,
                CatalogAccess::Automatic,
            )
        },
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
    ffi_guard(
        "converter_tts_catalog_probe_json_v3",
        std::ptr::null_mut(),
        || {
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
                CatalogAccess::Probe {
                    directory,
                    model_id: None,
                },
            )
        },
    )
}

/// Returns the install browser snapshot, including explicit-only Piper voices.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_catalog_manual_json_v3(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
    architecture: *const c_char,
    os_version: *const c_char,
    model_root: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_tts_catalog_manual_json_v3",
        std::ptr::null_mut(),
        || {
            speech_model_catalog_json(
                language,
                platform,
                android_api,
                architecture,
                os_version,
                model_root,
                CatalogAccess::Manual,
            )
        },
    )
}

/// Inspects and loads only the explicitly requested installed model.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_catalog_probe_model_json_v3(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
    architecture: *const c_char,
    os_version: *const c_char,
    model_root: *const c_char,
    espeak_data_directory: *const c_char,
    model_id: *const c_char,
) -> *mut c_char {
    ffi_guard(
        "converter_tts_catalog_probe_model_json_v3",
        std::ptr::null_mut(),
        || {
            let directory = match c_string(espeak_data_directory, "eSpeak data directory") {
                Ok(value) => value,
                Err(error) => return fail(error),
            };
            let model_id = match c_string(model_id, "requested model ID") {
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
                CatalogAccess::Probe {
                    directory,
                    model_id: Some(model_id),
                },
            )
        },
    )
}

enum CatalogAccess {
    Automatic,
    Manual,
    Probe {
        directory: String,
        model_id: Option<String>,
    },
}

unsafe fn speech_model_catalog_json(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
    architecture: *const c_char,
    os_version: *const c_char,
    model_root: *const c_char,
    access: CatalogAccess,
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
    let result = if matches!(access, CatalogAccess::Probe { .. }) {
        // Swift actor executors have small stacks. Keep the complete runtime
        // loading frame on the same stack budget as conversion and audition.
        std::thread::Builder::new()
            .name("converter-ffi-catalog-probe".into())
            .stack_size(8 * 1024 * 1024)
            .spawn(move || speech_model_snapshot_json(query, model_root, access))
            .map_err(|error| format!("Failed to start catalog probe: {error}"))
            .and_then(|thread| {
                thread
                    .join()
                    .map_err(|_| "Catalog probe panicked".to_owned())
            })
            .and_then(|result| result)
    } else {
        speech_model_snapshot_json(query, model_root, access)
    };
    match result {
        Ok(value) => CString::new(value).map_or_else(
            |_| fail("TTS catalog v3 contains an interior NUL byte".to_owned()),
            CString::into_raw,
        ),
        Err(error) => fail(error),
    }
}

// Do not inline a runtime-loading frame back onto the foreign caller's stack.
#[inline(never)]
fn speech_model_snapshot_json(
    query: converter_core::speech_model_library::CatalogQuery,
    model_root: String,
    access: CatalogAccess,
) -> Result<String, String> {
    let library = converter_core::speech_model_library::SpeechModelLibrary;
    let result = match access {
        CatalogAccess::Automatic if model_root.is_empty() => library.snapshot(query),
        CatalogAccess::Manual if model_root.is_empty() => library.manual_snapshot(query),
        access => {
            let store = converter_core::model_store::ModelStore::new(Path::new(&model_root));
            match access {
                CatalogAccess::Automatic => library.snapshot_with_inspection(query, &store, &[]),
                CatalogAccess::Manual => library.manual_snapshot_with_inspection(query, &store),
                CatalogAccess::Probe {
                    directory,
                    model_id: Some(model_id),
                } => {
                    if model_root.is_empty() {
                        return Err("An explicit model probe requires the model root".into());
                    }
                    library.snapshot_for_model_with_runtime_probe(
                        query,
                        &store,
                        &model_id,
                        |identity| probe_embedded_model(identity, store.root(), &directory, true),
                    )
                }
                CatalogAccess::Probe {
                    directory,
                    model_id: None,
                } => library.snapshot_with_runtime_probe(query, &store, |identity| {
                    probe_embedded_model(identity, store.root(), &directory, false)
                }),
            }
        }
    };
    let snapshot = result.map_err(|error| error.to_string())?;
    serde_json::to_string(&snapshot).map_err(|error| error.to_string())
}

fn probe_embedded_model(
    identity: &converter_core::speech_model_library::ModelIdentity,
    root: &Path,
    espeak_directory: &str,
    explicit: bool,
) -> converter_core::speech_model_library::RuntimeReadinessOutcome {
    use converter_core::speech_model_library::{ReadinessFailure, RuntimeReadinessOutcome};
    #[cfg(feature = "piper-runtime")]
    if identity.provider == "piper" {
        let prepared = (|| {
            let root = root.canonicalize().map_err(|error| error.to_string())?;
            super::piper_runtime_boundary::configure_piper_data_directory(Path::new(
                espeak_directory,
            ))?;
            let runtime = Arc::new(super::piper_runtime_boundary::EmbeddedPiperRuntime);
            let is_low = converter_core::model_catalog::model_by_id(&identity.model_id)
                .is_some_and(|model| {
                    model.metadata.presentation.quality
                        == converter_core::model_catalog::QualityTier::Low
                });
            if explicit && is_low {
                let revision = identity
                    .model_revision
                    .as_deref()
                    .ok_or("Piper model revision is missing")?;
                converter_core::piper::PreparedPiperModel::prepare_explicit_low(
                    &root,
                    &identity.model_id,
                    revision,
                    runtime,
                )
            } else {
                converter_core::piper::PreparedPiperModel::prepare(
                    &root,
                    &identity.model_id,
                    Path::new("model.onnx"),
                    Path::new("model.onnx.json"),
                    runtime,
                )
            }
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
    let _ = (identity, root, espeak_directory, explicit);
    RuntimeReadinessOutcome::Unavailable {
        failure: ReadinessFailure::RuntimeUnavailable,
    }
}

/// Returns the default local engine for a language and platform.
#[no_mangle]
pub unsafe extern "C" fn converter_tts_default_engine(
    language: *const c_char,
    platform: *const c_char,
    android_api: u32,
) -> *mut c_char {
    ffi_guard("converter_tts_default_engine", std::ptr::null_mut(), || {
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
    })
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
    ffi_guard(
        "converter_tts_installed_ready_engine",
        std::ptr::null_mut(),
        || {
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
        },
    )
}
