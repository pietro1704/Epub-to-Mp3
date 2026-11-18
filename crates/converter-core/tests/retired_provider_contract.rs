use converter_core::{
    model_catalog::MODELS,
    tts_preferences::{TtsPreferences, TtsSelection},
    tts_session::{builtin_descriptors, SessionSelection, CONTRACT_VERSION},
};

#[test]
fn saved_retired_selections_remain_readable_but_cannot_start_a_session() {
    for session in [
        serde_json::Value::Null,
        serde_json::json!({
            "version": CONTRACT_VERSION, "provider": "kokoro", "runtime": "kokoro",
            "model_id": "kokoro-82m", "model_revision": "retained-revision",
            "voice": null, "options": {}
        }),
    ] {
        let mut saved = serde_json::json!({
            "engine": "kokoro", "model_id": "kokoro-82m", "voice": null
        });
        if !session.is_null() {
            saved["session"] = session;
        }
        let selection: TtsSelection = serde_json::from_value(saved.clone()).unwrap();
        assert_eq!(
            selection.validate(Some("en-US")).unwrap_err(),
            "Unsupported TTS engine: kokoro"
        );
        assert!(SessionSelection::from_legacy(&selection).is_err());
        for preferences in [
            TtsPreferences {
                primary: selection.clone(),
                ..TtsPreferences::default()
            },
            TtsPreferences {
                secondary: Some(selection.clone()),
                ..TtsPreferences::default()
            },
        ] {
            assert!(preferences.validate(None).is_err());
        }
        // Rejection preserves the captured request; it never rewrites it to Piper.
        assert_eq!(serde_json::to_value(&selection).unwrap(), saved);
    }
    assert!(MODELS.iter().all(|model| model.engine != "kokoro"));
    assert!(builtin_descriptors()
        .iter()
        .all(|provider| provider.provider != "kokoro"));
}

#[tokio::test]
async fn retired_archives_are_rejected_before_download_or_installation_mutation() {
    use converter_core::model_store::{ModelArtifact, ModelManifest, ModelStore, ModelStoreError};
    let root = tempfile::tempdir().unwrap();
    let retained = root.path().join("kokoro-82m");
    std::fs::create_dir(&retained).unwrap();
    let model = retained.join("model.onnx");
    std::fs::write(&model, b"existing user model").unwrap();
    let manifest = ModelManifest {
        model_id: "kokoro-82m".into(),
        revision: None,
        artifacts: vec![ModelArtifact {
            name: "retired.tar.bz2".into(),
            url: "https://invalid.invalid/model".into(),
            sha256: "a".repeat(64),
        }],
    };
    let store = ModelStore::new(root.path());
    assert!(matches!(
        store.install_manifest(&manifest).await,
        Err(ModelStoreError::InvalidArchive(_))
    ));
    assert_eq!(std::fs::read(&model).unwrap(), b"existing user model");
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}
