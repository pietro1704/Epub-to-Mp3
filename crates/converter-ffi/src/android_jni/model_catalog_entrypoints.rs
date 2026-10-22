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
