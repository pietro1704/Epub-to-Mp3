use std::{collections::HashMap, net::SocketAddr, path::PathBuf, sync::Arc, time::Duration};

use axum::{
    extract::{Path as AxumPath, State},
    http::{header, StatusCode},
};
use converter_core::{
    config::AppConfig,
    model_store::ModelStoreError,
    tts_preferences::TtsPreferences,
    worker::{ConversionRequest, ConversionWorker, OutputManifest, ProgressEvent},
};
use futures_util::StreamExt;
use tokio::sync::{broadcast, RwLock};

use super::http_conversion_routes::{apply_manifest, create_job, record_progress};
use super::http_input_paths::uuid;
use super::http_job_routes::{cancel, resume_job, stream_job};
use super::http_model_routes::{install_model, models};
use super::http_output_routes::{chapters, output};
use super::http_runtime_state::{
    initial_job, load_snapshots, persist_snapshot, snapshot_path, AppState, CreateJob, Job,
    JobPhase, JobSnapshot, ModelInstaller, SseMessage, MAX_LOG_LINES,
};
use super::{app, register_speech_runtime, server_bind_address};

async fn post_conversion(config: AppConfig, body: serde_json::Value) -> String {
    let body = body.to_string();
    let request = format!("POST /api/convert HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body);
    http_fixture_request(config, request.as_bytes()).await
}

fn request(method: &str) -> axum::extract::Request {
    axum::http::Request::builder()
        .method(method)
        .uri("/")
        .body(axum::body::Body::empty())
        .unwrap()
}

async fn http_fixture_request(config: AppConfig, request: &[u8]) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, app(config)).await.unwrap();
    });
    let request = request.to_vec();
    let response = tokio::task::spawn_blocking(move || {
        use std::io::{Read, Write};
        let mut client = std::net::TcpStream::connect(address).unwrap();
        client
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        client.write_all(&request).unwrap();
        let mut bytes = Vec::new();
        client.read_to_end(&mut bytes).unwrap();
        String::from_utf8(bytes).unwrap()
    })
    .await
    .unwrap();
    server.abort();
    response
}

/// Place the default voice's artifacts where conversion looks for them. The
/// invalid EPUB fixtures stop every job before a model is opened.
fn place_default_voice(config: &AppConfig) {
    let directory = config
        .paths
        .models_dir
        .join("tts")
        .join(converter_core::tts_preferences::FABER_MODEL_ID);
    std::fs::create_dir_all(&directory).unwrap();
    std::fs::write(directory.join("model.onnx"), b"fixture").unwrap();
    std::fs::write(directory.join("model.onnx.json"), b"{}").unwrap();
}

/// Tests never reach the network: installing a voice fails unless a test
/// supplies its own installer.
fn refusing_installer() -> ModelInstaller {
    Arc::new(|_, model_id| {
        Box::pin(async move {
            Err(ModelStoreError::UnknownModel(format!(
                "{model_id} is unavailable in tests"
            )))
        })
    })
}

struct TestRoot(PathBuf);
impl TestRoot {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("converter-server-contract-{}", uuid()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn state(&self) -> AppState {
        let config = AppConfig::from_paths(converter_core::paths::resolve_paths_from(
            HashMap::<String, String>::new(),
            self.0.clone(),
        ));
        AppState {
            config,
            jobs: Arc::new(RwLock::new(HashMap::new())),
            model_installs: Default::default(),
            model_installer: refusing_installer(),
        }
    }
}
impl Drop for TestRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[path = "http_configuration_contract_tests.rs"]
mod configuration;
#[path = "http_job_creation_contract_tests.rs"]
mod job_creation;
#[path = "http_lifecycle_contract_tests.rs"]
mod lifecycle;
#[path = "http_outputs_contract_tests.rs"]
mod outputs;
