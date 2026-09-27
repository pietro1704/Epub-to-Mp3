use std::net::SocketAddr;

use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use converter_core::config::AppConfig;
use serde::Serialize;

#[derive(Clone)]
struct AppState {
    config: AppConfig,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
}

#[derive(Serialize)]
struct MetadataResponse {
    status: &'static str,
    engine: String,
    expected_wpm: u32,
    persistent_root: String,
    cache_dir: String,
    output_dir: String,
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, Json(HealthResponse { status: "ok" }))
}

async fn metadata(State(state): State<AppState>) -> impl IntoResponse {
    let paths = &state.config.paths;
    (
        StatusCode::OK,
        Json(MetadataResponse {
            status: "ok",
            engine: state.config.engine,
            expected_wpm: state.config.expected_wpm,
            persistent_root: paths.persistent_root.display().to_string(),
            cache_dir: paths.cache_dir.display().to_string(),
            output_dir: paths.output_dir.display().to_string(),
        }),
    )
}

fn app(config: AppConfig) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/api/metadata", get(metadata))
        .with_state(AppState { config })
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = AppConfig::from_env();
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port = std::env::var("PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(8000);
    let address: SocketAddr = format!("{host}:{port}").parse()?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    println!("converter-server listening on {address}");
    axum::serve(listener, app(config)).await?;
    Ok(())
}
