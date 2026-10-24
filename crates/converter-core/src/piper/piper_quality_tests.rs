use super::*;
use crate::model_catalog::{self, ModelPlatform};
use crate::tts_preferences::TtsSelection;

#[test]
fn low_quality_selections_are_rejected_for_primary_secondary_and_versioned_requests() {
    for id in ["en_US-lessac-low", "pt_BR-edresson-low", "custom-LOW"] {
        let selection = TtsSelection {
            engine: "piper".into(),
            model_id: Some(id.into()),
            voice: None,
            session: None,
        };
        assert!(selection.validate(None).is_err(), "accepted {id}");
        let mut preferences = crate::tts_preferences::TtsPreferences::default();
        preferences.secondary = Some(selection.clone());
        assert!(preferences.validate(None).is_err());
        let session = crate::tts_session::SessionSelection::from_legacy(&selection).unwrap();
        let descriptor = crate::tts_session::builtin_descriptors().remove(0);
        assert!(session.validate(&descriptor, "").is_err());
    }
    assert!(TtsSelection::default().validate(Some("pt-BR")).is_ok());
}

#[test]
fn low_quality_models_are_never_automatic_candidates_even_when_installed_and_ready() {
    for (language, id) in [("en", "en_US-lessac-low"), ("pt", "pt_BR-edresson-low")] {
        assert!(
            !model_catalog::candidates(language, ModelPlatform::Macos, None)
                .iter()
                .any(|model| model.id == id)
        );
        assert_eq!(
            model_catalog::installed_ready_engine(
                language,
                ModelPlatform::Macos,
                None,
                &[id],
                &[id]
            ),
            None
        );
    }
}

#[test]
fn legacy_paths_and_language_overrides_cannot_select_low_models() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("disk-low");
    fs::create_dir(&directory).unwrap();
    let medium = directory.join("en_US-lessac-medium.onnx");
    let low = root.path().join("en_US-lessac-low.onnx");
    let config = root.path().join("voice.json");
    fs::write(&medium, b"retained medium model").unwrap();
    fs::write(&low, b"retained low model").unwrap();
    fs::write(&config, br#"{"audio":{"quality":"medium"}}"#).unwrap();
    let mut selection = PiperConfig::new(&medium, &config);
    assert_eq!(select_model(&selection, None).unwrap(), medium);
    selection.language_models.insert("en".into(), low.clone());
    assert!(select_model(&selection, Some("en-US")).is_err());
    selection.model = low.clone();
    assert!(select_model(&selection, None).is_err());
    assert_eq!(fs::read(&low).unwrap(), b"retained low model");
}

#[test]
fn renamed_low_model_is_rejected_from_config_before_runtime_initialization() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("voice.onnx"), b"retained model").unwrap();
    let config = root.path().join("voice.json");
    let selection = PiperConfig::new(root.path().join("voice.onnx"), &config);
    for quality in ["low", " low ", "LOW", "x_low"] {
        fs::write(
            &config,
            serde_json::to_vec(&serde_json::json!({"audio":{"quality":quality}})).unwrap(),
        )
        .unwrap();
        assert!(
            select_model(&selection, None).is_err(),
            "accepted quality {quality:?}"
        );
        assert!(piper_runtime_init(&selection.model, &config)
            .unwrap_err()
            .to_string()
            .contains("quality"));
    }
}

struct PreparationProbe(std::sync::atomic::AtomicUsize);
impl PiperRuntime for PreparationProbe {
    fn status(&self) -> PiperRuntimeStatus {
        PiperRuntimeStatus {
            runtime_loaded: true,
            model_available: true,
            abi_compatible: true,
            engine_ready: true,
        }
    }
    fn init(&self, _: &Path, _: &Path) -> Result<(), PiperError> {
        self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok(())
    }
    fn synthesize(&self, _: &str, _: &Path) -> Result<(), PiperError> {
        panic!("rejected model must not reach synthesis")
    }
    fn shutdown(&self) {}
    fn supports_explicit_model_paths(&self) -> bool {
        true
    }
}

#[test]
fn prepared_medium_rechecks_quality_and_preserves_audio_when_config_changes_to_low() {
    let root = tempfile::tempdir().unwrap();
    let namespace = root.path().join("custom-medium");
    fs::create_dir(&namespace).unwrap();
    fs::write(namespace.join("voice.onnx"), b"retained model").unwrap();
    let config = namespace.join("voice.json");
    fs::write(&config, br#"{"audio":{"quality":"medium"}}"#).unwrap();
    let runtime = Arc::new(PreparationProbe(std::sync::atomic::AtomicUsize::new(0)));
    let prepared = PreparedPiperModel::prepare(
        root.path(),
        "custom-medium",
        Path::new("voice.onnx"),
        Path::new("voice.json"),
        runtime.clone(),
    )
    .unwrap();
    let output = root.path().join("retained.wav");
    fs::write(&output, b"existing audio").unwrap();
    fs::write(&config, br#"{"audio":{"quality":"x_low"}}"#).unwrap();
    assert!(prepared
        .synthesize("Speech", &output, &CancellationToken::default())
        .is_err());
    assert_eq!(runtime.0.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(fs::read(output).unwrap(), b"existing audio");
    assert_eq!(
        fs::read(namespace.join("voice.onnx")).unwrap(),
        b"retained model"
    );
}

#[cfg(unix)]
#[test]
fn renamed_symlink_cannot_hide_a_low_model() {
    let root = tempfile::tempdir().unwrap();
    let low = root.path().join("en_US-lessac-low.onnx");
    let alias = root.path().join("voice.onnx");
    fs::write(&low, b"retained model").unwrap();
    std::os::unix::fs::symlink(&low, &alias).unwrap();
    let config = root.path().join("voice.json");
    fs::write(&config, b"{}").unwrap();
    assert!(select_model(&PiperConfig::new(alias, config), None).is_err());
    assert!(low.is_file());
}
