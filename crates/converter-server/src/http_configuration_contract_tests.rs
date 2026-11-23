use super::*;

#[tokio::test]
async fn default_server_listener_is_loopback_only() {
    let address = server_bind_address(None, Some("0")).unwrap();
    let listener = tokio::net::TcpListener::bind(address).await.unwrap();
    assert!(listener.local_addr().unwrap().ip().is_loopback());
    assert_eq!(server_bind_address(None, None).unwrap().port(), 8000);
}

#[tokio::test]
async fn explicit_server_bind_configuration_is_preserved() {
    assert_eq!(
        server_bind_address(Some("0.0.0.0"), Some("9000")).unwrap(),
        "0.0.0.0:9000".parse::<SocketAddr>().unwrap()
    );
    let listener =
        tokio::net::TcpListener::bind(server_bind_address(Some("0.0.0.0"), Some("0")).unwrap())
            .await
            .unwrap();
    assert!(listener.local_addr().unwrap().ip().is_unspecified());
    assert_eq!(
        server_bind_address(Some("127.0.0.1"), Some("invalid"))
            .unwrap()
            .port(),
        8000
    );
    assert!(server_bind_address(Some("invalid-host"), None).is_err());
}

#[tokio::test]
async fn typed_http_preferences_reject_unavailable_or_malformed_selections() {
    let root = TestRoot::new();
    let config = root.state().config;
    let piper = post_conversion(
        config.clone(),
        serde_json::json!({
            "tts_preferences": TtsPreferences::default()
        }),
    )
    .await;
    // An absent catalog voice is installed on demand by the job itself, so the
    // selection is accepted and the request fails only for its missing upload.
    assert!(piper.starts_with("HTTP/1.1 400"), "{piper}");
    assert!(piper.contains("uploadId is required"), "{piper}");
    assert!(
        !config.paths.models_dir.exists(),
        "a refused request must not install anything"
    );
    // This process has no system speech adapter, and a Piper voice outside the
    // installable catalog cannot be fetched: neither could ever synthesize.
    let system = post_conversion(
        config.clone(),
        serde_json::json!({"upload_id":"any", "engine":"system"}),
    )
    .await;
    assert!(system.starts_with("HTTP/1.1 422"), "{system}");
    assert!(system.contains("no system speech adapter"), "{system}");
    let uncatalogued = post_conversion(
        config.clone(),
        serde_json::json!({"upload_id":"any", "tts_preferences":{
            "primary":{"engine":"piper","model_id":"xx_XX-nobody-medium","voice":null},
            "secondary":null,"allow_online_fallback":false
        }}),
    )
    .await;
    assert!(
        uncatalogued.starts_with("HTTP/1.1 4") && !uncatalogued.starts_with("HTTP/1.1 404"),
        "{uncatalogued}"
    );
    let unsupported = post_conversion(
        config.clone(),
        serde_json::json!({"upload_id":"legacy-upload", "engine":"kokoro"}),
    )
    .await;
    assert!(unsupported.starts_with("HTTP/1.1 400"), "{unsupported}");
    assert!(
        unsupported.contains("Unsupported conversion engine"),
        "{unsupported}"
    );
    let malformed = post_conversion(
        config.clone(),
        serde_json::json!({
            "tts_preferences":{"primary":{"engine":"unknown"}}
        }),
    )
    .await;
    assert!(malformed.starts_with("HTTP/1.1 400"), "{malformed}");
    let invalid_shape = post_conversion(
        config.clone(),
        serde_json::json!({
            "tts_preferences":"piper"
        }),
    )
    .await;
    assert!(invalid_shape.starts_with("HTTP/1.1 422"), "{invalid_shape}");
    place_default_voice(&config);
    let legacy = post_conversion(config, serde_json::json!({})).await;
    assert!(legacy.starts_with("HTTP/1.1 400"));
    assert!(legacy.contains("uploadId is required"));
}

#[tokio::test]
async fn typed_http_edge_selection_is_persisted_for_conversion_and_resume() {
    let root = TestRoot::new();
    let config = root.state().config;
    let upload = config.paths.uploads_dir.join("typed-upload");
    std::fs::create_dir_all(&upload).unwrap();
    // Invalid input reaches parsing but never invokes an online provider.
    std::fs::write(upload.join("source.epub"), b"invalid EPUB fixture").unwrap();
    let preferences = serde_json::json!({
        "primary":{"engine":"edge","model_id":null,"voice":"pt-BR-FranciscaNeural"},
        "secondary":null,"allow_online_fallback":true
    });
    let response = post_conversion(
        config.clone(),
        serde_json::json!({
            "upload_id":"typed-upload", "engine":"piper", "tts_preferences":preferences
        }),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    let body: serde_json::Value =
        serde_json::from_str(response.split_once("\r\n\r\n").unwrap().1).unwrap();
    let id = body["jobId"].as_str().unwrap();
    let snapshot: JobSnapshot =
        serde_json::from_slice(&std::fs::read(snapshot_path(&config, id)).unwrap()).unwrap();
    assert_eq!(
        serde_json::to_value(snapshot.tts_preferences).unwrap(),
        preferences
    );
    let request_path = config.paths.jobs_dir.join(format!("{id}.json"));
    tokio::time::timeout(Duration::from_secs(2), async {
        while !request_path.is_file() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let request: serde_json::Value =
        serde_json::from_slice(&std::fs::read(request_path).unwrap()).unwrap();
    assert_eq!(request["metadata"]["tts_preferences"], preferences);
    assert_eq!(
        request["metadata"]["models_root"],
        config
            .paths
            .models_dir
            .join("tts")
            .to_string_lossy()
            .as_ref()
    );
}

async fn persisted_worker_request(config: &AppConfig, id: &str) -> serde_json::Value {
    let request_path = config.paths.jobs_dir.join(format!("{id}.json"));
    tokio::time::timeout(Duration::from_secs(2), async {
        while !request_path.is_file() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the shared worker must persist its request");
    serde_json::from_slice(&std::fs::read(request_path).unwrap()).unwrap()
}

fn invalid_upload(config: &AppConfig, id: &str) {
    let upload = config.paths.uploads_dir.join(id);
    std::fs::create_dir_all(&upload).unwrap();
    // Invalid input reaches parsing but never invokes a speech provider.
    std::fs::write(upload.join("source.epub"), b"invalid EPUB fixture").unwrap();
}

fn created_job_id(response: &str) -> String {
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    let body: serde_json::Value =
        serde_json::from_str(response.split_once("\r\n\r\n").unwrap().1).unwrap();
    body["jobId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn typed_http_local_selection_reaches_the_shared_worker() {
    let root = TestRoot::new();
    let config = root.state().config;
    invalid_upload(&config, "local-upload");
    place_default_voice(&config);
    let preferences = serde_json::to_value(TtsPreferences::app_default(true)).unwrap();
    let response = post_conversion(
        config.clone(),
        serde_json::json!({"upload_id":"local-upload", "tts_preferences":preferences}),
    )
    .await;
    let id = created_job_id(&response);
    let request = persisted_worker_request(&config, &id).await;
    assert_eq!(request["metadata"]["tts_preferences"], preferences);
    assert_eq!(request["metadata"]["engine"], "piper");
    let models_root = config.paths.models_dir.join("tts");
    assert_eq!(
        request["metadata"]["piper_model"],
        models_root
            .join(converter_core::tts_preferences::FABER_MODEL_ID)
            .join("model.onnx")
            .to_string_lossy()
            .as_ref()
    );
}

#[tokio::test]
async fn typed_http_legacy_engine_is_captured_once_as_typed_preferences() {
    let root = TestRoot::new();
    let config = root.state().config;
    invalid_upload(&config, "legacy-upload");
    let response = post_conversion(
        config.clone(),
        serde_json::json!({
            "upload_id":"legacy-upload", "engine":"edge", "voice":"pt-BR-FranciscaNeural"
        }),
    )
    .await;
    let id = created_job_id(&response);
    let expected = serde_json::json!({
        "primary":{"engine":"edge","model_id":null,"voice":"pt-BR-FranciscaNeural"},
        "secondary":null,"allow_online_fallback":true
    });
    let snapshot: JobSnapshot =
        serde_json::from_slice(&std::fs::read(snapshot_path(&config, &id)).unwrap()).unwrap();
    assert_eq!(
        serde_json::to_value(snapshot.tts_preferences).unwrap(),
        expected
    );
    assert_eq!(snapshot.engine.as_deref(), Some("edge"));
    let request = persisted_worker_request(&config, &id).await;
    assert_eq!(request["metadata"]["tts_preferences"], expected);
}

#[test]
fn startup_registers_the_embedded_piper_runtime() {
    register_speech_runtime(None).unwrap();
    assert!(converter_core::piper::registered_runtime().is_some());
    let missing = std::env::temp_dir().join(format!("missing-espeak-data-{}", uuid()));
    assert!(register_speech_runtime(Some(missing.as_os_str())).is_err());
}

#[tokio::test]
async fn models_are_listed_without_installing_and_unknown_models_are_refused() {
    let root = TestRoot::new();
    let state = root.state();
    let listed = models(State(state.clone())).await;
    assert_eq!(listed.status(), StatusCode::OK);
    let body = axum::body::to_bytes(listed.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let faber = body["models"]
        .as_array()
        .unwrap()
        .iter()
        .find(|model| model["id"] == converter_core::tts_preferences::FABER_MODEL_ID)
        .expect("the default voice must be installable");
    assert_eq!(faber["installed"], false);
    assert_eq!(faber["engine"], "piper");
    assert!(faber["downloadBytes"].as_u64().unwrap() > 0);
    // A voice the conversion refuses must be neither offered nor installable.
    let refused = "pt_BR-edresson-low";
    assert!(body["models"]
        .as_array()
        .unwrap()
        .iter()
        .all(|model| model["id"] != refused));
    let refused_install = install_model(AxumPath(refused.into()), State(state.clone())).await;
    assert_eq!(refused_install.status(), StatusCode::NOT_FOUND);
    let unknown = install_model(AxumPath("not-a-model".into()), State(state.clone())).await;
    assert_eq!(unknown.status(), StatusCode::NOT_FOUND);
    assert!(
        !state.config.paths.models_dir.exists(),
        "listing or refusing a model must not create the model store"
    );
}

#[tokio::test]
async fn server_serves_the_api_only_and_no_static_web_bundle() {
    let root = TestRoot::new();
    let config = root.state().config;
    let page = http_fixture_request(
        config.clone(),
        b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(
        page.starts_with("HTTP/1.1 404"),
        "unexpected response: {page}"
    );
    let asset = http_fixture_request(
        config,
        b"GET /assets/app.js HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(
        asset.starts_with("HTTP/1.1 404"),
        "unexpected response: {asset}"
    );
}
