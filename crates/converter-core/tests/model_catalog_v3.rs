use converter_core::{
    model_catalog::ModelPlatform,
    model_store::ModelStore,
    speech_model_library::{
        CatalogQuery, InstallationState, ReadinessFailure, ReadinessState,
        RuntimeReadinessObservation, RuntimeReadinessOutcome, SelectionReason, SpeechModelLibrary,
    },
};

fn portuguese_macos_query() -> CatalogQuery {
    CatalogQuery {
        language: "pt-BR".into(),
        platform: ModelPlatform::Macos,
        android_api: None,
        architecture: "arm64".into(),
        os_version: Some("15.5".into()),
    }
}

#[test]
fn model_catalog_v3_does_not_promote_routing_or_placeholders_to_evidence() {
    let snapshot = SpeechModelLibrary
        .snapshot(portuguese_macos_query())
        .expect("static catalogue must be valid");
    let value = serde_json::to_value(snapshot).unwrap();

    assert_eq!(value["schema_version"], 3);
    let placeholder = value["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["identity"]["model_id"] == "piper-default")
        .unwrap();
    assert_eq!(placeholder["distribution"]["installable"], false);
    assert_eq!(placeholder["language_evidence"]["routing_tags"][5], "pt");
    assert_eq!(
        placeholder["language_evidence"]["exact_tags"],
        serde_json::json!([])
    );
    assert_eq!(placeholder["selection"]["selectable"], false);
    assert!(placeholder["selection"]["reasons"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("not_installable")));
}

#[test]
fn model_catalog_v3_exposes_faber_identity_presentation_and_distribution() {
    let snapshot = SpeechModelLibrary
        .snapshot(portuguese_macos_query())
        .expect("static catalogue must be valid");
    let value = serde_json::to_value(snapshot).unwrap();
    let faber = value["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["identity"]["model_id"] == "pt_BR-faber-medium")
        .unwrap();

    assert_eq!(faber["identity"]["provider"], "piper");
    assert_eq!(faber["identity"]["runtime"], "piper");
    assert_eq!(
        faber["identity"]["model_revision"],
        concat!(
            "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7:",
            "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f"
        )
    );
    assert_eq!(faber["presentation"]["model_name"], "Faber");
    assert_eq!(faber["presentation"]["family_name"], "Piper");
    assert_eq!(faber["presentation"]["quality"], "medium");
    assert_eq!(
        faber["presentation"]["voice_choices"][0]["voice_id"],
        serde_json::Value::Null
    );
    assert_eq!(faber["presentation"]["voice_choices"][0]["name"], "Faber");
    assert_eq!(faber["distribution"]["download_bytes"], 63_206_149);
    assert_eq!(
        faber["distribution"]["installed_bytes"],
        serde_json::json!(63_206_149)
    );
    assert_eq!(
        faber["distribution"]["artifacts"].as_array().unwrap().len(),
        2
    );
    assert_eq!(faber["licence"]["id"], "CC0-1.0");
    assert_eq!(faber["licence"]["category"], "dataset");
    assert_eq!(faber["licence"]["validation"], "partial");
    assert_eq!(faber["licence"]["requires_acceptance"], false);
}

#[test]
fn model_catalog_v3_is_deterministic_and_keeps_domain_states_separate() {
    let library = SpeechModelLibrary;
    let first = library.snapshot(portuguese_macos_query()).unwrap();
    let second = library.snapshot(portuguese_macos_query()).unwrap();
    assert_eq!(first, second);

    let value = serde_json::to_value(first).unwrap();
    assert_eq!(value["synthesis_contract_version"], 2);
    assert_eq!(
        value["generated_from_catalog_revision"]
            .as_str()
            .unwrap()
            .len(),
        64
    );
    assert_eq!(value["default_selection"]["provider"], "piper");
    assert_eq!(value["default_selection"]["model_id"], "pt_BR-faber-medium");
    assert_eq!(
        value["default_selection"]["model_revision"],
        concat!(
            "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7:",
            "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f"
        )
    );
    assert!(value["providers"].as_array().unwrap().len() >= 4);

    let entries = value["entries"].as_array().unwrap();
    let faber = entries
        .iter()
        .find(|entry| entry["identity"]["model_id"] == "pt_BR-faber-medium")
        .unwrap();
    assert_eq!(faber["compatibility"]["compatible"], true);
    assert_eq!(faber["compatibility"]["reasons"], serde_json::json!([]));
    assert_eq!(faber["installation"]["state"], "not_inspected");
    assert_eq!(faber["readiness"]["state"], "not_inspected");
    assert_eq!(faber["selection"]["selectable"], false);

    let kokoro = entries
        .iter()
        .find(|entry| entry["identity"]["model_id"] == "kokoro-82m")
        .unwrap();
    assert_eq!(kokoro["compatibility"]["compatible"], false);
    assert!(kokoro["compatibility"]["reasons"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("unsupported_language")));
}

#[test]
fn model_catalog_v2_preserves_representative_legacy_entries() {
    let value: serde_json::Value =
        serde_json::from_str(&converter_core::tts_session::catalog_json()).unwrap();
    assert_eq!(value["version"], 2);
    let models = value["models"].as_array().unwrap();
    let find = |model_id: &str| models.iter().find(|model| model["id"] == model_id).unwrap();

    let faber = find("pt_BR-faber-medium");
    assert_eq!(faber["engine"], "piper");
    assert_eq!(faber["languages"], serde_json::json!(["pt"]));
    assert_eq!(faber["runtime"], "piper");
    assert_eq!(faber["runtime_available"], true);
    assert_eq!(faber["download_bytes"], 63_206_149);
    assert_eq!(faber["artifacts"].as_array().unwrap().len(), 2);
    assert_eq!(
        faber["revision"],
        concat!(
            "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7:",
            "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f"
        )
    );
    assert!(faber.get("presentation").is_none());
    assert!(faber.get("licence").is_none());

    let placeholder = find("piper-default");
    assert_eq!(placeholder["artifacts"], serde_json::json!([]));
    assert_eq!(placeholder["revision"], "");
    assert_eq!(placeholder["runtime_available"], true);

    let kokoro = find("kokoro-82m");
    assert_eq!(kokoro["engine"], "kokoro");
    assert_eq!(kokoro["languages"], serde_json::json!(["en"]));
    assert_eq!(kokoro["runtime_available"], false);
    assert_eq!(kokoro["artifacts"].as_array().unwrap().len(), 1);
}

#[test]
fn model_catalog_v3_preserves_disabled_low_quality_policy() {
    let snapshot = SpeechModelLibrary
        .snapshot(portuguese_macos_query())
        .expect("static catalogue must be valid");
    let value = serde_json::to_value(snapshot).unwrap();
    let edresson = value["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["identity"]["model_id"] == "pt_BR-edresson-low")
        .unwrap();

    assert_eq!(edresson["compatibility"]["compatible"], false);
    assert!(edresson["compatibility"]["reasons"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("quality_disabled")));
    assert_eq!(edresson["selection"]["selectable"], false);
}

#[test]
fn model_catalog_v3_reports_target_compatibility_reasons() {
    let snapshot = SpeechModelLibrary
        .snapshot(CatalogQuery {
            language: "pt-BR".into(),
            platform: ModelPlatform::Android,
            android_api: Some(28),
            architecture: "arm64-v8a".into(),
            os_version: Some("9".into()),
        })
        .unwrap();
    let value = serde_json::to_value(snapshot).unwrap();
    let placeholder = value["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["identity"]["model_id"] == "piper-default")
        .unwrap();

    assert_eq!(placeholder["compatibility"]["compatible"], false);
    assert!(placeholder["compatibility"]["reasons"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("android_api_too_low")));
}

#[test]
fn model_catalog_v3_projects_offline_installation_and_runtime_states_without_private_paths() {
    let root = tempfile::tempdir().unwrap();
    let library = SpeechModelLibrary;
    let catalog_only = library.snapshot(portuguese_macos_query()).unwrap();
    let faber_identity = catalog_only
        .entries
        .iter()
        .find(|entry| entry.identity.model_id == "pt_BR-faber-medium")
        .unwrap()
        .identity
        .clone();
    let snapshot = library
        .snapshot_with_inspection(
            portuguese_macos_query(),
            &ModelStore::new(root.path()),
            &[RuntimeReadinessObservation {
                model_id: faber_identity.model_id,
                model_revision: faber_identity.model_revision,
                outcome: RuntimeReadinessOutcome::Unavailable {
                    failure: ReadinessFailure::RuntimeUnavailable,
                },
            }],
        )
        .unwrap();
    let faber = snapshot
        .entries
        .iter()
        .find(|entry| entry.identity.model_id == "pt_BR-faber-medium")
        .unwrap();

    assert_eq!(faber.installation.state, InstallationState::Missing);
    assert_eq!(faber.readiness.state, ReadinessState::Unavailable);
    assert!(faber
        .selection
        .reasons
        .contains(&SelectionReason::InstallationMissing));
    assert!(faber
        .selection
        .reasons
        .contains(&SelectionReason::RuntimeUnavailable));
    assert_eq!(snapshot.default_selection, catalog_only.default_selection);
    assert!(!serde_json::to_string(&snapshot)
        .unwrap()
        .contains(root.path().to_string_lossy().as_ref()));
}
