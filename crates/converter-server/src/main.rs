//! HTTP compatibility entrypoint; Apple/Flutter/Web clients use embedded Rust.
mod http_conversion_routes;
mod http_input_paths;
mod http_job_routes;
mod http_metadata_routes;
mod http_model_routes;
mod http_output_routes;
mod http_runtime_state;
mod http_speech_selection;
mod http_upload_routes;

use axum::extract::DefaultBodyLimit;
use axum::routing::get;
use axum::routing::post;
use axum::Router;
use converter_core::config::AppConfig;
use http_conversion_routes::create_job;
use http_job_routes::{cancel, log, recent_jobs, resumable_jobs, resume_job, status, stream_job};
use http_metadata_routes::{contract, health, metadata};
use http_model_routes::{catalog_installer, install_model, models};
use http_output_routes::{chapters, fulltext, output};
use http_runtime_state::{load_snapshots, AppState};
use http_upload_routes::{local_upload, upload};
use std::ffi::OsStr;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::RwLock;

// Keep a concrete server-side ceiling above normal EPUB sizes while preventing unbounded request bodies.
const MAX_UPLOAD_BYTES: usize = 100 * 1024 * 1024;
const API_CONTRACT_VERSION: &str = "1";

fn app(config: AppConfig) -> Router {
    let recovered_jobs = load_snapshots(&config);
    Router::new()
        .route("/health", get(health))
        .route("/api/health", get(health))
        .route("/api/contract", get(contract))
        .route("/api/metadata", get(metadata))
        .route(
            "/api/uploads",
            post(upload).layer(DefaultBodyLimit::max(MAX_UPLOAD_BYTES)),
        )
        .route("/api/uploads/local", post(local_upload))
        .route("/api/convert", post(create_job))
        .route("/api/models", get(models))
        .route("/api/models/{id}/install", post(install_model))
        .route("/api/jobs/resumable", get(resumable_jobs))
        .route("/api/jobs/recent", get(recent_jobs))
        .route("/api/jobs/{id}", get(status))
        .route("/api/jobs/{id}/stream", get(stream_job))
        .route("/api/jobs/{id}/cancel", post(cancel))
        .route("/api/jobs/{id}/resume", post(resume_job))
        .route("/api/jobs/{id}/log", get(log))
        .route("/api/jobs/{id}/fulltext", get(fulltext))
        .route("/api/outputs/{id}/{file}", get(output))
        .route("/api/streams/{id}/chapters/{index}", get(chapters))
        .with_state(AppState {
            config,
            jobs: Arc::new(RwLock::new(recovered_jobs)),
            model_installs: Default::default(),
            model_installer: catalog_installer(),
        })
}
fn server_bind_address(
    host: Option<&str>,
    port: Option<&str>,
) -> Result<SocketAddr, std::net::AddrParseError> {
    let host = host.unwrap_or("127.0.0.1");
    let port = port
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(8000);
    format!("{host}:{port}").parse()
}

/// Register the embedded Piper runtime shared with the CLI. Voice models are
/// installed only by an explicit action, never at startup or by a conversion.
fn register_speech_runtime(espeak_data: Option<&OsStr>) -> Result<(), String> {
    // Online voices and model downloads share one process-wide TLS provider.
    let _ = rustls::crypto::ring::default_provider().install_default();
    converter_ffi::piper_runtime_register_embedded();
    match espeak_data {
        Some(directory) => converter_ffi::configure_piper_data_directory(Path::new(directory)),
        None => Ok(()),
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    register_speech_runtime(std::env::var_os("ESPEAK_DATA_DIRECTORY").as_deref())?;
    let config = AppConfig::from_env();
    let address = server_bind_address(
        std::env::var("HOST").ok().as_deref(),
        std::env::var("PORT").ok().as_deref(),
    )?;
    tokio::fs::create_dir_all(&config.paths.uploads_dir).await?;
    tokio::fs::create_dir_all(&config.paths.job_inputs_dir).await?;
    tokio::fs::create_dir_all(&config.paths.output_dir).await?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    println!("converter-server listening on {address}");
    axum::serve(
        listener,
        app(config).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}

#[cfg(test)]
#[path = "http_contract_tests.rs"]
mod tests;
