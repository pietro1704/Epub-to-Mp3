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
    assert!(piper.starts_with("HTTP/1.1 422"), "{piper}");
    assert!(piper.contains("does not embed Piper"));
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
        "secondary":null,"allow_online_fallback":false
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
