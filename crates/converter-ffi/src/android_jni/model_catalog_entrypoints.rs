#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_NativeTtsOptions_nativeValidateSessionOptions(
    mut env: JNIEnv<'_>,
    _object: JObject<'_>,
    raw: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_NativeTtsOptions_nativeValidateSessionOptions",
        std::ptr::null_mut(),
        || {
            let validation = read_string(&mut env, raw).and_then(|json| {
                let options: EmbeddedConversionOptionsV1 =
                    serde_json::from_str(&json).map_err(|error| error.to_string())?;
                if options.contract_version != Some(2) {
                    return Err("Version 2 contract is required".into());
                }
                options.validate_contract()
            });
            match validation {
                Ok(()) => std::ptr::null_mut(),
                Err(error) => env
                    .new_string(error)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw()),
            }
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsCatalogV3(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsCatalogV3",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let query = converter_core::speech_model_library::CatalogQuery {
                language: String::new(),
                platform: converter_core::model_catalog::ModelPlatform::Android,
                android_api: None,
                architecture: std::env::consts::ARCH.into(),
                os_version: None,
            };
            let snapshot =
                match converter_core::speech_model_library::SpeechModelLibrary.snapshot(query) {
                    Ok(snapshot) => snapshot,
                    Err(error) => return fail(error.to_string()),
                };
            let json = match serde_json::to_string(&snapshot) {
                Ok(json) => json,
                Err(error) => return fail(error.to_string()),
            };
            env.new_string(json)
                .map_or(std::ptr::null_mut(), |value| value.into_raw())
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeJobLog(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    job_id: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeJobLog",
        std::ptr::null_mut(),
        || {
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
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeLastError(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeLastError",
        std::ptr::null_mut(),
        || {
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
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsDefaultEngine(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    language: JString<'_>,
    platform: JString<'_>,
    android_api: jint,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsDefaultEngine",
        std::ptr::null_mut(),
        || {
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
        },
    )
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
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsInstalledReadyEngine",
        std::ptr::null_mut(),
        || {
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
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsManualCatalogV3(
    mut env: JNIEnv<'_>,
    _object: JObject<'_>,
    language: JString<'_>,
    android_api: jint,
    architecture: JString<'_>,
    os_version: JString<'_>,
    model_root: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsManualCatalogV3",
        std::ptr::null_mut(),
        || {
            android_explicit_catalog_json(
                &mut env,
                android_api,
                [language, architecture, os_version, model_root],
                None,
            )
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsCatalogProbeModelV3(
    mut env: JNIEnv<'_>,
    _object: JObject<'_>,
    language: JString<'_>,
    android_api: jint,
    architecture: JString<'_>,
    os_version: JString<'_>,
    model_root: JString<'_>,
    espeak_data_directory: JString<'_>,
    model_id: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsCatalogProbeModelV3",
        std::ptr::null_mut(),
        || {
            android_explicit_catalog_json(
                &mut env,
                android_api,
                [language, architecture, os_version, model_root],
                Some([espeak_data_directory, model_id]),
            )
        },
    )
}

fn android_explicit_catalog_json(
    env: &mut JNIEnv<'_>,
    android_api: jint,
    target: [JString<'_>; 4],
    probe: Option<[JString<'_>; 2]>,
) -> jstring {
    clear_last_error();
    let mut read = |value| {
        CString::new(read_string(env, value)?)
            .map_err(|_| "Catalog arguments must not contain NUL bytes".to_owned())
    };
    let catalog = (|| {
        let [language, architecture, os_version, model_root] = target;
        let target = [
            read(language)?,
            read(architecture)?,
            read(os_version)?,
            read(model_root)?,
        ];
        let probe = probe
            .map(|[directory, model_id]| Ok::<_, String>([read(directory)?, read(model_id)?]))
            .transpose()?;
        Ok::<_, String>(explicit_android_catalog(
            android_api,
            target.each_ref().map(CString::as_c_str),
            probe
                .as_ref()
                .map(|probe| probe.each_ref().map(CString::as_c_str)),
        ))
    })();
    let result = match catalog {
        Ok(value) if value.is_null() => return std::ptr::null_mut(),
        Ok(value) => unsafe { CString::from_raw(value) },
        Err(error) => return fail(error),
    };
    match env.new_string(result.to_string_lossy()) {
        Ok(value) => value.into_raw(),
        Err(error) => fail(error.to_string()),
    }
}

fn explicit_android_catalog(
    android_api: jint,
    [language, architecture, os_version, model_root]: [&CStr; 4],
    probe: Option<[&CStr; 2]>,
) -> *mut c_char {
    let android_api = android_api.max(0) as u32;
    unsafe {
        if let Some([directory, model_id]) = probe {
            converter_tts_catalog_probe_model_json_v3(
                language.as_ptr(),
                c"android".as_ptr(),
                android_api,
                architecture.as_ptr(),
                os_version.as_ptr(),
                model_root.as_ptr(),
                directory.as_ptr(),
                model_id.as_ptr(),
            )
        } else {
            converter_tts_catalog_manual_json_v3(
                language.as_ptr(),
                c"android".as_ptr(),
                android_api,
                architecture.as_ptr(),
                os_version.as_ptr(),
                model_root.as_ptr(),
            )
        }
    }
}

#[cfg(test)]
mod explicit_model_catalog_jni_tests {
    use super::*;

    #[test]
    fn explicit_android_catalog_preserves_target_and_probes_only_the_requested_id() {
        let root = tempfile::tempdir().unwrap();
        let root_path = CString::new(root.path().to_str().unwrap()).unwrap();
        let target = [c"en-US", c"arm64-v8a", c"15", root_path.as_c_str()];
        let decode = |pointer: *mut c_char| {
            assert!(!pointer.is_null());
            let json = unsafe { CString::from_raw(pointer) };
            serde_json::from_slice::<serde_json::Value>(json.as_bytes()).unwrap()
        };
        let manual = decode(explicit_android_catalog(35, target, None));
        assert_eq!(manual["target"]["platform"], "android");
        assert_eq!(manual["target"]["android_api"], 35);
        assert_eq!(manual["target"]["language"], "en-US");
        assert_eq!(manual["target"]["architecture"], "arm64-v8a");
        assert_eq!(manual["target"]["os_version"], "15");
        assert_eq!(
            manual["default_selection"]["model_id"],
            "pt_BR-faber-medium"
        );

        let probe = decode(explicit_android_catalog(
            35,
            target,
            Some([c"/no-phonemizer-needed", c"en_US-lessac-low"]),
        ));
        let entries = probe["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        let entry = &entries[0];
        assert_eq!(entry["identity"]["model_id"], "en_US-lessac-low");
        assert_eq!(entry["presentation"]["quality"], "low");
        assert_eq!(entry["compatibility"]["compatible"], true);
        assert_eq!(entry["installation"]["state"], "missing");
        assert_eq!(entry["readiness"]["state"], "not_inspected");
        assert_eq!(entry["selection"]["selectable"], false);
        assert!(manual["entries"].as_array().unwrap().contains(entry));
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }
}

/// Base languages with at least one catalog model on Android (contract
/// `converter_tts_catalog_languages_json_v1`).
#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsCatalogLanguages(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    android_api: jint,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsCatalogLanguages",
        std::ptr::null_mut(),
        || {
            let value = unsafe {
                converter_tts_catalog_languages_json_v1(c"android".as_ptr(), android_api.max(0) as u32)
            };
            language_json_string(&env, value)
        },
    )
}

/// Resolves the narration for a book language (pure; never downloads).
#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsResolveLanguageModel(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    request_json: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsResolveLanguageModel",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let Ok(request) = read_string(&mut env, request_json) else {
                return std::ptr::null_mut();
            };
            let Ok(request) = CString::new(request) else {
                return std::ptr::null_mut();
            };
            let value =
                unsafe { converter_tts_resolve_language_model_json_v1(request.as_ptr()) };
            language_json_string(&env, value)
        },
    )
}

/// Language analysis of a book file. Blocking: call off the UI thread.
#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeBookLanguage(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeBookLanguage",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let Ok(path) = read_string(&mut env, path) else {
                return std::ptr::null_mut();
            };
            let Ok(path) = CString::new(path) else {
                return std::ptr::null_mut();
            };
            let value = unsafe { converter_book_language_json_v1(path.as_ptr()) };
            language_json_string(&env, value)
        },
    )
}

fn language_json_string(env: &JNIEnv<'_>, value: *mut std::os::raw::c_char) -> jstring {
    if value.is_null() {
        return std::ptr::null_mut();
    }
    let text = unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned();
    unsafe { converter_string_free(value) };
    env.new_string(text)
        .map_or(std::ptr::null_mut(), |value| value.into_raw())
}
