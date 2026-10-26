use super::*;
use std::{
    collections::HashSet,
    path::{Component, PathBuf},
    sync::{atomic::AtomicBool, Mutex, OnceLock},
};

static ACTIVE_MODEL_INSTALLS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

#[repr(C)]
pub struct ConverterModelInstallOperation {
    operation: Mutex<converter_core::model_store::ModelInstallOperation>,
    cancellation: Arc<AtomicBool>,
    registry_key: String,
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_create(
    model_id: *const c_char,
    root: *const c_char,
    available_bytes: u64,
) -> *mut ConverterModelInstallOperation {
    clear_last_error();
    create_model_install_operation(model_id, root, available_bytes, false)
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_recover(
    model_id: *const c_char,
    root: *const c_char,
    available_bytes: u64,
) -> *mut ConverterModelInstallOperation {
    clear_last_error();
    create_model_install_operation(model_id, root, available_bytes, true)
}

unsafe fn create_model_install_operation(
    model_id: *const c_char,
    root: *const c_char,
    available_bytes: u64,
    recover_only: bool,
) -> *mut ConverterModelInstallOperation {
    let model_id = match c_string(model_id, "model id") {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let root = match c_string(root, "model storage root") {
        Ok(value) => PathBuf::from(value),
        Err(error) => return fail(error),
    };
    let registry_key = format!("{}:{}", normalized_root(&root).display(), model_id);
    let active = ACTIVE_MODEL_INSTALLS.get_or_init(Default::default);
    {
        let mut active = active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !active.insert(registry_key.clone()) {
            return fail(format!("duplicate model installation request: {model_id}"));
        }
    }
    let cancellation = Arc::new(AtomicBool::new(false));
    let operation = if recover_only {
        converter_core::model_store::ModelInstallOperation::recover_catalog(
            root,
            &model_id,
            available_bytes,
            cancellation.clone(),
        )
    } else {
        converter_core::model_store::ModelInstallOperation::begin_catalog(
            root,
            &model_id,
            available_bytes,
            cancellation.clone(),
        )
        .map(Some)
    };
    let operation = match operation {
        Ok(Some(operation)) => operation,
        Ok(None) => {
            active
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&registry_key);
            return std::ptr::null_mut();
        }
        Err(error) => {
            active
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&registry_key);
            return fail(error.to_string());
        }
    };
    Box::into_raw(Box::new(ConverterModelInstallOperation {
        operation: Mutex::new(operation),
        cancellation,
        registry_key,
    }))
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_plan_json(
    handle: *const ConverterModelInstallOperation,
) -> *mut c_char {
    operation_json(handle, |operation| serde_json::to_string(&operation.plan()))
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_event_json(
    handle: *const ConverterModelInstallOperation,
) -> *mut c_char {
    operation_json(handle, |operation| serde_json::to_string(operation.event()))
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_record_progress(
    handle: *const ConverterModelInstallOperation,
    artifact_index: usize,
    downloaded_bytes: u64,
) -> bool {
    operation_mut(handle, |operation| {
        operation
            .record_download_progress(artifact_index, downloaded_bytes)
            .map(|_| ())
    })
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_accept_download(
    handle: *const ConverterModelInstallOperation,
    artifact_index: usize,
    downloaded_path: *const c_char,
) -> bool {
    clear_last_error();
    let path = match c_string(downloaded_path, "downloaded artifact path") {
        Ok(value) => PathBuf::from(value),
        Err(error) => {
            fail::<()>(error);
            return false;
        }
    };
    operation_mut(handle, |operation| {
        operation.accept_download(artifact_index, &path).map(|_| ())
    })
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_publish(
    handle: *const ConverterModelInstallOperation,
) -> *mut c_char {
    clear_last_error();
    if handle.is_null() {
        return fail("invalid null model install operation".into());
    }
    let operation = &*handle;
    let mut operation = operation
        .operation
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match operation.publish() {
        Ok(installed) => installed
            .first()
            .and_then(|item| item.path.parent())
            .map(|path| path.to_string_lossy().into_owned())
            .and_then(|path| CString::new(path).ok())
            .map_or_else(
                || fail("model install operation produced no target path".into()),
                CString::into_raw,
            ),
        Err(error) => fail(error.to_string()),
    }
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_fail(
    handle: *const ConverterModelInstallOperation,
    kind: *const c_char,
    message: *const c_char,
) -> bool {
    clear_last_error();
    let kind = match c_string(kind, "model install failure kind") {
        Ok(value) => value,
        Err(error) => {
            fail::<()>(error);
            return false;
        }
    };
    let message = match c_string(message, "model install failure message") {
        Ok(value) => value,
        Err(error) => {
            fail::<()>(error);
            return false;
        }
    };
    operation_mut(handle, |operation| operation.fail(&kind, &message))
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_cancel(
    handle: *const ConverterModelInstallOperation,
) {
    if handle.is_null() {
        return;
    }
    let handle = &*handle;
    handle
        .cancellation
        .store(true, std::sync::atomic::Ordering::Release);
    let mut operation = handle
        .operation
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Err(error) = operation.cancel() {
        fail::<()>(error.to_string());
    }
}

#[no_mangle]
pub unsafe extern "C" fn converter_tts_model_install_operation_free(
    handle: *mut ConverterModelInstallOperation,
) {
    if handle.is_null() {
        return;
    }
    let handle = Box::from_raw(handle);
    ACTIVE_MODEL_INSTALLS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&handle.registry_key);
}

unsafe fn operation_json(
    handle: *const ConverterModelInstallOperation,
    encode: impl FnOnce(
        &converter_core::model_store::ModelInstallOperation,
    ) -> Result<String, serde_json::Error>,
) -> *mut c_char {
    clear_last_error();
    if handle.is_null() {
        return fail("invalid null model install operation".into());
    }
    let operation = (&*handle)
        .operation
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match encode(&operation) {
        Ok(value) => CString::new(value).map_or_else(
            |_| fail("model install JSON contains an interior NUL byte".into()),
            CString::into_raw,
        ),
        Err(error) => fail(error.to_string()),
    }
}

unsafe fn operation_mut(
    handle: *const ConverterModelInstallOperation,
    mutate: impl FnOnce(
        &mut converter_core::model_store::ModelInstallOperation,
    ) -> Result<(), converter_core::model_store::ModelStoreError>,
) -> bool {
    clear_last_error();
    if handle.is_null() {
        fail::<()>("invalid null model install operation".into());
        return false;
    }
    let mut operation = (&*handle)
        .operation
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match mutate(&mut operation) {
        Ok(()) => true,
        Err(error) => {
            fail::<()>(error.to_string());
            false
        }
    }
}

fn normalized_root(root: &std::path::Path) -> PathBuf {
    let mut existing = root;
    let mut suffix = Vec::new();
    while !existing.exists() {
        if let Some(name) = existing.file_name() {
            suffix.push(name.to_owned());
        }
        let Some(parent) = existing.parent() else {
            break;
        };
        existing = parent;
    }
    let mut normalized = std::fs::canonicalize(existing).unwrap_or_else(|_| existing.to_path_buf());
    for component in suffix.into_iter().rev() {
        if !matches!(
            PathBuf::from(&component).components().next(),
            Some(Component::Normal(_))
        ) {
            return root.to_path_buf();
        }
        normalized.push(component);
    }
    normalized
}
