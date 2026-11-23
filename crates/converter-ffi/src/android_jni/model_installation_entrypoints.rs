#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstall(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    model_id: JString<'_>,
    url: JString<'_>,
    sha256: JString<'_>,
    root: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstall",
        std::ptr::null_mut(),
        || {
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
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallManifest(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    model_id: JString<'_>,
    artifacts_json: JString<'_>,
    root: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallManifest",
        std::ptr::null_mut(),
        || {
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
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallCatalogManifest(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    model_id: JString<'_>,
    root: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(env.get_raw(), "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallCatalogManifest", std::ptr::null_mut(), || {
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
    })
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelMetadata(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    model_id: JString<'_>,
    root: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelMetadata",
        std::ptr::null_mut(),
        || {
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
            let metadata =
                unsafe { converter_tts_model_metadata(model_id.as_ptr(), root.as_ptr()) };
            if metadata.is_null() {
                return std::ptr::null_mut();
            }
            let value = unsafe { CStr::from_ptr(metadata) }
                .to_string_lossy()
                .into_owned();
            unsafe { converter_string_free(metadata) };
            env.new_string(value)
                .map_or(std::ptr::null_mut(), |value| value.into_raw())
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelRemove(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    model_id: JString<'_>,
    root: JString<'_>,
) -> jboolean {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelRemove",
        0,
        || {
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
        },
    )
}

// Model install operation: the handle crosses JNI as a `jlong` owned by the
// Kotlin channel until `nativeTtsModelInstallOperationFree`.

fn install_operation_ptr(handle: jlong) -> *mut ConverterModelInstallOperation {
    handle as usize as *mut ConverterModelInstallOperation
}

fn install_operation_string(env: &JNIEnv<'_>, value: *mut std::os::raw::c_char) -> jstring {
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

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationCreate(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    model_id: JString<'_>,
    root: JString<'_>,
    available_bytes: jlong,
    recover: jboolean,
) -> jlong {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationCreate",
        0,
        || {
            let (Ok(model_id), Ok(root)) = (
                read_string(&mut env, model_id),
                read_string(&mut env, root),
            ) else {
                return 0;
            };
            let (Ok(model_id), Ok(root)) = (CString::new(model_id), CString::new(root)) else {
                return 0;
            };
            let available = available_bytes.max(0) as u64;
            let handle = unsafe {
                if recover != 0 {
                    converter_tts_model_install_operation_recover(
                        model_id.as_ptr(),
                        root.as_ptr(),
                        available,
                    )
                } else {
                    converter_tts_model_install_operation_create(
                        model_id.as_ptr(),
                        root.as_ptr(),
                        available,
                    )
                }
            };
            handle as usize as jlong
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationPlan(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationPlan",
        std::ptr::null_mut(),
        || {
            let value = unsafe {
                converter_tts_model_install_operation_plan_json(install_operation_ptr(handle))
            };
            install_operation_string(&env, value)
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationEvent(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationEvent",
        std::ptr::null_mut(),
        || {
            let value = unsafe {
                converter_tts_model_install_operation_event_json(install_operation_ptr(handle))
            };
            install_operation_string(&env, value)
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationRecordProgress(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    artifact_index: jint,
    downloaded_bytes: jlong,
) -> jboolean {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationRecordProgress",
        0,
        || {
            if artifact_index < 0 || downloaded_bytes < 0 {
                return 0;
            }
            unsafe {
                converter_tts_model_install_operation_record_progress(
                    install_operation_ptr(handle),
                    artifact_index as usize,
                    downloaded_bytes as u64,
                ) as jboolean
            }
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationAccept(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    artifact_index: jint,
    downloaded_path: JString<'_>,
) -> jboolean {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationAccept",
        0,
        || {
            if artifact_index < 0 {
                return 0;
            }
            let Ok(path) = read_string(&mut env, downloaded_path) else {
                return 0;
            };
            let Ok(path) = CString::new(path) else {
                return 0;
            };
            unsafe {
                converter_tts_model_install_operation_accept_download(
                    install_operation_ptr(handle),
                    artifact_index as usize,
                    path.as_ptr(),
                ) as jboolean
            }
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationPublish(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationPublish",
        std::ptr::null_mut(),
        || {
            let value = unsafe {
                converter_tts_model_install_operation_publish(install_operation_ptr(handle))
            };
            install_operation_string(&env, value)
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationFail(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    kind: JString<'_>,
    message: JString<'_>,
) -> jboolean {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationFail",
        0,
        || {
            let (Ok(kind), Ok(message)) = (
                read_string(&mut env, kind),
                read_string(&mut env, message),
            ) else {
                return 0;
            };
            let (Ok(kind), Ok(message)) = (CString::new(kind), CString::new(message)) else {
                return 0;
            };
            unsafe {
                converter_tts_model_install_operation_fail(
                    install_operation_ptr(handle),
                    kind.as_ptr(),
                    message.as_ptr(),
                ) as jboolean
            }
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationCancel(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationCancel",
        (),
        || unsafe { converter_tts_model_install_operation_cancel(install_operation_ptr(handle)) },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationFree(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationFree",
        (),
        || unsafe { converter_tts_model_install_operation_free(install_operation_ptr(handle)) },
    )
}
