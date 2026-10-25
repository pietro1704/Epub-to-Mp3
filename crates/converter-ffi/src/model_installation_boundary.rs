use super::*;

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
        revision: converter_core::model_catalog::revision_from_hashes(
            artifacts.iter().map(|artifact| artifact.sha256.as_str()),
        ),
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
