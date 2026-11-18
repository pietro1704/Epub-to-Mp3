//! Explicit voice-model listing and installation. A conversion never installs a model.
use super::http_runtime_state::{AppState, ModelInstaller};
use axum::extract::Path as AxumPath;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use converter_core::model_catalog::{TtsModelDescriptor, MODELS};
use converter_core::model_store::{ModelStore, ModelStoreError};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelStatus {
    id: &'static str,
    engine: &'static str,
    download_bytes: u64,
    installed: bool,
}

/// Only voices a conversion accepts are offered or installed.
fn installable() -> impl Iterator<Item = &'static TtsModelDescriptor> {
    MODELS
        .iter()
        .filter(|model| model.runtime_available && !model.artifacts.is_empty())
}

pub(super) fn installable_model(id: &str) -> Option<&'static TtsModelDescriptor> {
    installable().find(|model| model.id == id)
}

fn models_root(state: &AppState) -> PathBuf {
    state.config.paths.models_dir.join("tts")
}

fn store_error(status: StatusCode, error: ModelStoreError) -> Response {
    (
        status,
        Json(serde_json::json!({ "detail": error.to_string() })),
    )
        .into_response()
}

/// Listing reports artifact presence, which is what a conversion requires.
/// Checksums are verified by the explicit install action rather than on every
/// request to an unauthenticated route.
fn artifacts_present(root: &Path, model: &TtsModelDescriptor) -> bool {
    let directory = root.join(model.id);
    model
        .artifacts
        .iter()
        .all(|artifact| directory.join(artifact.name).is_file())
}

pub(super) async fn models(State(state): State<AppState>) -> Response {
    let root = models_root(&state);
    let listed = tokio::task::spawn_blocking(move || {
        installable()
            .map(|model| ModelStatus {
                id: model.id,
                engine: model.engine,
                download_bytes: model.download_bytes,
                installed: artifacts_present(&root, model),
            })
            .collect::<Vec<_>>()
    })
    .await;
    match listed {
        Ok(models) => (
            StatusCode::OK,
            Json(serde_json::json!({ "models": models })),
        )
            .into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

/// The production installer: download from the catalog with checksum verification.
pub(super) fn catalog_installer() -> ModelInstaller {
    Arc::new(|root, model_id| Box::pin(install(root, model_id)))
}

/// Install one catalog voice, one installation at a time: concurrent requests
/// for a model would race on its directory, so later callers wait.
pub(super) async fn install_serialized(
    state: &AppState,
    model_id: &'static str,
) -> Result<(), ModelStoreError> {
    let _installing = state.model_installs.lock().await;
    (state.model_installer)(models_root(state), model_id).await
}

/// Verify the model's checksums and download it only when they do not hold.
async fn install(root: PathBuf, model_id: &'static str) -> Result<(), ModelStoreError> {
    let manifest = ModelStore::catalog_manifest(model_id)?;
    let (inspected_root, inspected) = (root.clone(), manifest.clone());
    let verified = tokio::task::spawn_blocking(move || {
        ModelStore::new(inspected_root).is_manifest_installed(&inspected)
    })
    .await
    .map_err(|error| ModelStoreError::Io(std::io::Error::other(error)))??;
    if !verified {
        ModelStore::new(root).install_manifest(&manifest).await?;
    }
    Ok(())
}

pub(super) async fn install_model(
    AxumPath(id): AxumPath<String>,
    State(state): State<AppState>,
) -> Response {
    let Some(model) = installable_model(&id) else {
        return store_error(StatusCode::NOT_FOUND, ModelStoreError::UnknownModel(id));
    };
    // Detached from the request so a disconnecting client cannot abort a
    // download half-way.
    let installation = tokio::spawn(async move { install_serialized(&state, model.id).await });
    match installation.await {
        Ok(Ok(())) => (
            StatusCode::OK,
            Json(serde_json::json!({ "id": model.id, "installed": true })),
        )
            .into_response(),
        Ok(Err(error @ ModelStoreError::Http(_))) => store_error(StatusCode::BAD_GATEWAY, error),
        Ok(Err(error)) => store_error(StatusCode::INTERNAL_SERVER_ERROR, error),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}
