//! Compatibility health/version and selected-runtime metadata routes.
use super::http_runtime_state::{AppState, ContractResponse, HealthResponse, MetadataResponse};
use super::API_CONTRACT_VERSION;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;

pub(super) async fn health() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(HealthResponse {
            status: "healthy",
            contract_version: API_CONTRACT_VERSION,
        }),
    )
}
pub(super) async fn contract() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(ContractResponse {
            version: API_CONTRACT_VERSION,
            backend: "rust",
            capabilities: vec!["uploads", "jobs", "sse", "epub", "edge", "piper"],
        }),
    )
}
pub(super) async fn metadata(State(state): State<AppState>) -> impl IntoResponse {
    let paths = &state.config.paths;
    (
        StatusCode::OK,
        Json(MetadataResponse {
            status: "ok",
            engine: state.config.engine.clone(),
            expected_wpm: state.config.expected_wpm,
            persistent_root: paths.persistent_root.display().to_string(),
            cache_dir: paths.cache_dir.display().to_string(),
            output_dir: paths.output_dir.display().to_string(),
        }),
    )
}
