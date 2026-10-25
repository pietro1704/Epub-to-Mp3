use super::*;
use crate::model_catalog::{TtsArtifactDescriptor, TtsModelDescriptor};

fn descriptor_with(
    artifacts: Vec<TtsArtifactDescriptor>,
    download_bytes: u64,
) -> TtsModelDescriptor {
    let mut descriptor = MODELS[0].clone();
    descriptor.artifacts = Box::leak(artifacts.into_boxed_slice());
    descriptor.download_bytes = download_bytes;
    descriptor
}

fn artifact(
    name: &'static str,
    url: &'static str,
    sha256: &'static str,
    bytes: u64,
) -> TtsArtifactDescriptor {
    TtsArtifactDescriptor {
        name,
        url,
        sha256,
        bytes,
    }
}

#[test]
fn model_catalog_v3_rejects_invalid_artifact_identity() {
    let valid_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let cases = [
        descriptor_with(
            vec![artifact(
                "model.onnx",
                "http://example.invalid/model",
                valid_hash,
                1,
            )],
            1,
        ),
        descriptor_with(
            vec![artifact(
                "model.onnx",
                "https://example.invalid/model",
                "bad",
                1,
            )],
            1,
        ),
        descriptor_with(
            vec![artifact(
                "../model.onnx",
                "https://example.invalid/model",
                valid_hash,
                1,
            )],
            1,
        ),
        descriptor_with(
            vec![
                artifact(
                    "model.onnx",
                    "https://example.invalid/model-a",
                    valid_hash,
                    1,
                ),
                artifact(
                    "model.onnx",
                    "https://example.invalid/model-b",
                    valid_hash,
                    1,
                ),
            ],
            2,
        ),
        descriptor_with(
            vec![artifact(
                "model.onnx",
                "https://example.invalid/model",
                valid_hash,
                1,
            )],
            2,
        ),
    ];

    for descriptor in cases {
        assert!(validate_catalog(&[descriptor]).is_err());
    }

    let duplicate = MODELS[0].clone();
    assert!(validate_catalog(&[duplicate.clone(), duplicate]).is_err());
}

fn descriptor_with_metadata(metadata: crate::model_catalog::ModelMetadata) -> TtsModelDescriptor {
    let mut descriptor = MODELS[0].clone();
    descriptor.metadata = Box::leak(Box::new(metadata));
    descriptor
}

#[test]
fn model_catalog_v3_rejects_ambiguous_labels_voices_languages_and_licences() {
    let base = *MODELS[0].metadata;

    let mut empty_label = base;
    empty_label.presentation.model_name = "";

    let duplicated_voices = Box::leak(
        vec![
            crate::model_catalog::VoiceDescriptor {
                voice_id: Some("speaker-0"),
                name: "Faber",
            },
            crate::model_catalog::VoiceDescriptor {
                voice_id: Some("speaker-0"),
                name: "Duplicate",
            },
        ]
        .into_boxed_slice(),
    );
    let mut ambiguous_voice = base;
    ambiguous_voice.presentation.voice_choices = duplicated_voices;

    let duplicated_languages = Box::leak(
        vec![
            crate::model_catalog::ExactLanguageDescriptor {
                tag: "pt-BR",
                frontend: Some("espeak-ng:pt-br"),
                validation: crate::model_catalog::LanguageValidation::RuntimeValidated,
            },
            crate::model_catalog::ExactLanguageDescriptor {
                tag: "pt-BR",
                frontend: Some("espeak-ng:pt-br"),
                validation: crate::model_catalog::LanguageValidation::ArtifactDeclared,
            },
        ]
        .into_boxed_slice(),
    );
    let mut ambiguous_language = base;
    ambiguous_language.exact_languages = duplicated_languages;

    let unrelated_languages = Box::leak(
        vec![crate::model_catalog::ExactLanguageDescriptor {
            tag: "fr-FR",
            frontend: None,
            validation: crate::model_catalog::LanguageValidation::ArtifactDeclared,
        }]
        .into_boxed_slice(),
    );
    let mut unrelated_language = base;
    unrelated_language.exact_languages = unrelated_languages;

    let mut missing_terms_fingerprint = base;
    missing_terms_fingerprint.licence.requires_acceptance = true;
    missing_terms_fingerprint.licence.terms_fingerprint = None;

    for metadata in [
        empty_label,
        ambiguous_voice,
        ambiguous_language,
        unrelated_language,
        missing_terms_fingerprint,
    ] {
        assert!(validate_catalog(&[descriptor_with_metadata(metadata)]).is_err());
    }
}

#[test]
fn model_catalog_v3_labels_do_not_change_model_identity() {
    let original = MODELS[0].clone();
    let mut renamed_metadata = *original.metadata;
    renamed_metadata.presentation.model_name = "Renamed Faber label";
    let renamed = descriptor_with_metadata(renamed_metadata);

    assert_eq!(model_revision(&original), model_revision(&renamed));
    assert_ne!(
        catalog_revision_for(&[original]).unwrap(),
        catalog_revision_for(&[renamed]).unwrap()
    );
}

#[test]
fn inspected_snapshot_keeps_installation_and_runtime_readiness_separate() {
    let root = tempfile::tempdir().unwrap();
    let store = crate::model_store::ModelStore::new(root.path());
    let library = SpeechModelLibrary;
    let catalog_only = library
        .snapshot(crate::speech_model_library::tests_query())
        .unwrap();
    let faber_identity = catalog_only
        .entries
        .iter()
        .find(|entry| entry.identity.model_id == "pt_BR-faber-medium")
        .unwrap()
        .identity
        .clone();
    let readiness = RuntimeReadinessObservation {
        model_id: faber_identity.model_id.clone(),
        model_revision: faber_identity.model_revision.clone(),
        outcome: RuntimeReadinessOutcome::Unavailable {
            failure: ReadinessFailure::RuntimeUnavailable,
        },
    };

    let inspected = library
        .snapshot_with_inspection(
            crate::speech_model_library::tests_query(),
            &store,
            &[readiness],
        )
        .unwrap();
    let faber = inspected
        .entries
        .iter()
        .find(|entry| entry.identity.model_id == "pt_BR-faber-medium")
        .unwrap();

    assert_eq!(faber.installation.state, InstallationState::Missing);
    assert_eq!(faber.readiness.state, ReadinessState::Unavailable);
    assert_eq!(
        faber.readiness.failure,
        Some(ReadinessFailure::RuntimeUnavailable)
    );
    assert!(!faber.selection.selectable);
    assert!(faber
        .selection
        .reasons
        .contains(&SelectionReason::InstallationMissing));
    assert!(faber
        .selection
        .reasons
        .contains(&SelectionReason::RuntimeUnavailable));
    assert_eq!(inspected.default_selection, catalog_only.default_selection);
    assert!(!serde_json::to_string(&inspected)
        .unwrap()
        .contains(root.path().to_string_lossy().as_ref()));
}

#[test]
fn readiness_observation_requires_the_exact_model_revision() {
    let root = tempfile::tempdir().unwrap();
    let store = crate::model_store::ModelStore::new(root.path());
    let readiness = RuntimeReadinessObservation {
        model_id: "pt_BR-faber-medium".into(),
        model_revision: Some("wrong-revision".into()),
        outcome: RuntimeReadinessOutcome::Ready {
            active_runtime_revision: "runtime-v1".into(),
        },
    };

    let snapshot = SpeechModelLibrary
        .snapshot_with_inspection(
            crate::speech_model_library::tests_query(),
            &store,
            &[readiness],
        )
        .unwrap();
    let faber = snapshot
        .entries
        .iter()
        .find(|entry| entry.identity.model_id == "pt_BR-faber-medium")
        .unwrap();

    assert_eq!(faber.readiness.state, ReadinessState::NotInspected);
    assert_eq!(faber.readiness.active_runtime_revision, None);
    assert!(faber
        .selection
        .reasons
        .contains(&SelectionReason::ReadinessNotInspected));
}

#[test]
fn selection_requires_both_verified_installation_and_ready_runtime() {
    let mut snapshot = SpeechModelLibrary
        .snapshot(crate::speech_model_library::tests_query())
        .unwrap();
    let faber = snapshot
        .entries
        .iter_mut()
        .find(|entry| entry.identity.model_id == "pt_BR-faber-medium")
        .unwrap();

    faber.installation = InstallationStatus {
        state: InstallationState::Installed,
        verified_revision: faber.identity.model_revision.clone(),
        installed_bytes: Some(63_206_149),
    };
    faber.readiness = ReadinessStatus {
        state: ReadinessState::Ready,
        active_runtime_revision: Some("embedded-piper-v1".into()),
        failure: None,
    };
    faber.selection = super::inspection::selection_for(faber);

    assert!(faber.selection.selectable);
    assert!(faber.selection.reasons.is_empty());

    faber.readiness = ReadinessStatus {
        state: ReadinessState::Unavailable,
        active_runtime_revision: None,
        failure: Some(ReadinessFailure::RuntimeUnavailable),
    };
    faber.selection = super::inspection::selection_for(faber);
    assert!(!faber.selection.selectable);
    assert_eq!(
        faber.selection.reasons,
        vec![SelectionReason::RuntimeUnavailable]
    );
}
