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
