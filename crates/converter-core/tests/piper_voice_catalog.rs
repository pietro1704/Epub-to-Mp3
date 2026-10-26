use converter_core::{
    model_catalog::{model_revision, LanguageValidation, ModelPlatform, QualityTier, MODELS},
    model_store::ModelStore,
    speech_model_library::{CatalogQuery, InstallationState, SpeechModelLibrary},
    tts_preferences::TtsSelection,
    tts_session::SessionSelection,
};

const ADDITIONAL_VOICES: &[(&str, &str, &str, u64)] = &[
    ("pt_BR-cadu-medium", "pt-BR", "espeak-ng:pt-br", 62_955_084),
    ("pt_BR-jeff-medium", "pt-BR", "espeak-ng:pt-br", 62_955_085),
    ("es_ES-davefx-medium", "es-ES", "espeak-ng:es", 63_206_111),
    ("en_US-ljspeech-medium", "en-US", "espeak-ng:en", 63_536_351),
    ("en_US-ljspeech-high", "en-US", "espeak-ng:en", 114_203_981),
    ("en_GB-cori-medium", "en-GB", "espeak-ng:en", 63_536_345),
    ("en_US-kristin-medium", "en-US", "espeak-ng:en", 63_536_347),
];

fn query(locale: &str) -> CatalogQuery {
    CatalogQuery {
        language: locale.into(),
        platform: ModelPlatform::Macos,
        android_api: None,
        architecture: "x86_64".into(),
        os_version: Some("12.0".into()),
    }
}

#[test]
fn additional_voices_keep_audited_artifacts_single_speakers_and_literal_identity() {
    let legacy: serde_json::Value =
        serde_json::from_str(&converter_core::tts_session::catalog_json()).unwrap();
    for &(id, locale, frontend, total_bytes) in ADDITIONAL_VOICES {
        let snapshot = SpeechModelLibrary.snapshot(query(locale)).unwrap();
        let entry = snapshot
            .entries
            .iter()
            .find(|entry| entry.identity.model_id == id)
            .unwrap();
        assert_eq!(entry.identity.provider, "piper");
        assert!(entry.compatibility.compatible);
        assert!(entry.distribution.installable);
        assert_eq!(entry.distribution.download_bytes, Some(total_bytes));
        assert_eq!(entry.distribution.installed_bytes, Some(total_bytes));
        assert_eq!(
            entry
                .distribution
                .artifacts
                .iter()
                .map(|a| a.bytes)
                .sum::<u64>(),
            total_bytes
        );
        assert_eq!(entry.presentation.voice_choices.len(), 1);
        assert_eq!(entry.presentation.voice_choices[0].voice_id, None);
        assert_eq!(entry.language_evidence.exact_tags[0].tag, locale);
        assert_eq!(
            entry.language_evidence.exact_tags[0].frontend,
            Some(frontend)
        );
        assert_eq!(
            entry.language_evidence.exact_tags[0].validation,
            LanguageValidation::ArtifactDeclared
        );

        let model = MODELS.iter().find(|model| model.id == id).unwrap();
        let manifest = ModelStore::catalog_manifest(id).unwrap();
        assert_eq!(manifest.revision, model_revision(model));
        assert_eq!(entry.identity.model_revision, manifest.revision);
        assert_eq!(manifest.artifacts.len(), 2);
        for artifact in &entry.distribution.artifacts {
            assert!(artifact
                .url
                .contains("/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/"));
            assert_eq!(artifact.sha256.len(), 64);
        }
        let v2 = legacy["models"]
            .as_array()
            .unwrap()
            .iter()
            .find(|model| model["id"] == id)
            .unwrap();
        assert_eq!(
            v2["revision"].as_str(),
            entry.identity.model_revision.as_deref()
        );
        let selection = TtsSelection {
            engine: "piper".into(),
            model_id: Some(id.into()),
            voice: None,
            session: None,
        };
        let session = SessionSelection::from_legacy(&selection).unwrap();
        let provider = snapshot
            .providers
            .iter()
            .find(|p| p.provider == "piper")
            .unwrap();
        session.validate(provider, locale).unwrap();
        assert!(session.validate(provider, "ar").is_err());
        assert_eq!(
            snapshot.default_selection.model_id.as_deref(),
            Some("pt_BR-faber-medium")
        );
    }
}

#[test]
fn catalogue_presence_does_not_claim_installation_readiness_or_select_a_new_voice() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let snapshot = SpeechModelLibrary
        .snapshot_with_inspection(query("pt-BR"), &store, &[])
        .unwrap();
    for &(id, _, _, _) in ADDITIONAL_VOICES {
        let entry = snapshot
            .entries
            .iter()
            .find(|entry| entry.identity.model_id == id)
            .unwrap();
        assert_eq!(entry.installation.state, InstallationState::Missing);
        assert!(!entry.selection.selectable);
    }
    assert!(root.path().read_dir().unwrap().next().is_none());
}

#[test]
fn high_quality_and_model_creator_licence_are_not_dataset_or_benchmark_claims() {
    use converter_core::model_catalog::{LicenceCategory, LicenceValidation};
    let snapshot = SpeechModelLibrary.snapshot(query("en-US")).unwrap();
    let high = snapshot
        .entries
        .iter()
        .find(|entry| entry.identity.model_id == "en_US-ljspeech-high")
        .unwrap();
    assert_eq!(high.presentation.quality, QualityTier::High);
    assert_eq!(high.licence.id, Some("LicenseRef-Public-Domain"));
    assert_eq!(high.licence.category, LicenceCategory::ModelWeights);
    assert_eq!(high.licence.validation, LicenceValidation::CreatorDeclared);
    let cadu = snapshot
        .entries
        .iter()
        .find(|entry| entry.identity.model_id == "pt_BR-cadu-medium")
        .unwrap();
    assert_eq!(cadu.licence.category, LicenceCategory::Dataset);
    assert_eq!(cadu.licence.validation, LicenceValidation::Partial);
    assert!(snapshot
        .entries
        .iter()
        .all(|entry| entry.identity.model_id != "en_US-lessac-medium"));
}

#[test]
fn runtime_probe_never_loads_missing_models_or_creates_installation_state() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let inspected = SpeechModelLibrary
        .snapshot_with_inspection(query("pt-BR"), &store, &[])
        .unwrap();
    let probed = SpeechModelLibrary
        .snapshot_with_runtime_probe(query("pt-BR"), &store, |_| {
            panic!("Missing/corrupt/foreign models cannot become runtime load requests")
        })
        .unwrap();
    assert_eq!(probed, inspected);
    assert!(root.path().read_dir().unwrap().next().is_none());
}
