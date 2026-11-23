use super::*;
use crate::tts_preferences::{TtsSelection, FABER_MODEL_ID};

#[test]
fn defaults_use_managed_models_without_installation_or_online_consent() {
    let root = tempfile::tempdir().unwrap();
    let resolved = ConversionSelectionInput::default()
        .resolve(root.path(), true)
        .unwrap();
    assert_eq!(resolved.preferences.primary.engine, "piper");
    assert_eq!(resolved.preferences.secondary.unwrap().engine, "system");
    assert!(!resolved.preferences.allow_online_fallback);
    assert_eq!(
        resolved.piper_model.unwrap(),
        root.path().join(FABER_MODEL_ID).join("model.onnx")
    );
    assert!(root.path().read_dir().unwrap().next().is_none());
}

#[test]
fn captured_secondary_model_does_not_replace_primary_voice_or_preferences() {
    let root = tempfile::tempdir().unwrap();
    let model_root = root.path().to_str().unwrap();
    let mut preferences = TtsPreferences::app_default(true);
    let piper = preferences.primary.clone();
    preferences.primary = TtsSelection {
        engine: "edge".into(),
        voice: Some("pt-BR-FranciscaNeural".into()),
        model_id: None,
        session: None,
    };
    preferences.secondary = Some(piper);
    preferences.allow_online_fallback = true;
    let resolved = ConversionSelectionInput {
        preferences: Some(&preferences),
        engine: Some("system"),
        voice: Some("ignored"),
        models_root: Some(model_root),
        ..Default::default()
    }
    .resolve(root.path(), true)
    .unwrap();
    assert_eq!(resolved.preferences, preferences);
    assert_eq!(
        resolved.piper_config.unwrap(),
        root.path().join(FABER_MODEL_ID).join("model.onnx.json")
    );
    assert!(root.path().read_dir().unwrap().next().is_none());
}

#[test]
fn manual_selection_requires_installed_files_and_rejects_path_escape() {
    let root = tempfile::tempdir().unwrap();
    let mut input = ConversionSelectionInput {
        engine: Some("piper"),
        model_id: Some(FABER_MODEL_ID),
        models_root: Some(root.path().to_str().unwrap()),
        ..Default::default()
    };
    assert!(input.resolve(root.path(), false).is_err());
    let namespace = root.path().join(FABER_MODEL_ID);
    std::fs::create_dir(&namespace).unwrap();
    std::fs::write(namespace.join("model.onnx"), b"retained model").unwrap();
    std::fs::write(namespace.join("model.onnx.json"), b"{}").unwrap();
    assert!(input.resolve(root.path(), false).is_ok());
    for escape in ["../escape", "/absolute", "a\\b", ""] {
        input.model_path = Some(escape);
        assert!(input.resolve(root.path(), false).is_err());
    }
    assert_eq!(
        std::fs::read(namespace.join("model.onnx")).unwrap(),
        b"retained model"
    );
}
