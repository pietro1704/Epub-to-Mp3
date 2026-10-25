use super::*;
use crate::model_catalog::MODELS;

#[tokio::test]
async fn publishes_downloaded_artifact_without_deleting_it_first() {
    let root = tempfile::tempdir().unwrap();
    let temporary = root.path().join("model.onnx.part");
    let destination = root.path().join("model.onnx");
    tokio::fs::write(&temporary, b"verified model bytes")
        .await
        .unwrap();

    tokio::fs::rename(&temporary, &destination).await.unwrap();

    assert!(!temporary.exists());
    assert_eq!(
        tokio::fs::read(&destination).await.unwrap(),
        b"verified model bytes"
    );
}

#[tokio::test]
async fn rejects_unverified_install_before_network_access() {
    let store = ModelStore::new(std::env::temp_dir().join("epubtomp3-model-store-test"));
    let error = store.install(&MODELS[0], None, None).await.unwrap_err();
    assert!(matches!(error, ModelStoreError::MissingUrl));
}

#[tokio::test]
async fn rejects_insecure_install_before_network_access() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let checksum = "0".repeat(64);
    let error = store
        .install(
            &MODELS[0],
            Some("http://example.invalid/model"),
            Some(&checksum),
        )
        .await
        .unwrap_err();
    assert!(matches!(error, ModelStoreError::InsecureUrl));
}

#[tokio::test]
async fn reports_missing_metadata_without_error() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    assert_eq!(store.installed_metadata("missing").await.unwrap(), None);
}

#[tokio::test]
async fn remove_is_idempotent() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    store.remove("missing").await.unwrap();
}

#[tokio::test]
async fn manifest_rejects_empty_artifact_list_without_network_access() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let manifest = ModelManifest {
        model_id: "kokoro-82m".to_owned(),
        revision: None,
        artifacts: Vec::new(),
    };
    let error = store.install_manifest(&manifest).await.unwrap_err();
    assert!(matches!(error, ModelStoreError::EmptyManifest));
}

#[tokio::test]
async fn manifest_rejects_path_traversal_before_network_access() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let manifest = ModelManifest {
        model_id: "kokoro-82m".to_owned(),
        revision: None,
        artifacts: vec![ModelArtifact {
            name: "../escape.bin".to_owned(),
            url: "https://example.invalid/model".to_owned(),
            sha256: "0".repeat(64),
        }],
    };
    let error = store.install_manifest(&manifest).await.unwrap_err();
    assert!(matches!(error, ModelStoreError::InvalidArtifactName(_)));
}

#[tokio::test]
async fn manifest_rejects_insecure_url_before_network_access() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let manifest = ModelManifest {
        model_id: "kokoro-82m".to_owned(),
        revision: None,
        artifacts: vec![ModelArtifact {
            name: "model.onnx".to_owned(),
            url: "http://example.invalid/model".to_owned(),
            sha256: "0".repeat(64),
        }],
    };
    let error = store.install_manifest(&manifest).await.unwrap_err();
    assert!(matches!(error, ModelStoreError::InsecureUrl));
}

#[test]
fn a_voice_is_installed_only_with_both_verified_artifacts() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let directory = root.path().join("test-piper");
    std::fs::create_dir_all(&directory).unwrap();
    let model = b"test model artifact";
    let config = b"{\"audio\":{\"sample_rate\":22050}}";
    let manifest = ModelManifest {
        model_id: "test-piper".into(),
        revision: None,
        artifacts: vec![
            ModelArtifact {
                name: "model.onnx".into(),
                url: "https://example.invalid/model".into(),
                sha256: hex::encode(Sha256::digest(model)),
            },
            ModelArtifact {
                name: "model.onnx.json".into(),
                url: "https://example.invalid/config".into(),
                sha256: hex::encode(Sha256::digest(config)),
            },
        ],
    };
    std::fs::write(directory.join("model.onnx"), model).unwrap();
    assert!(!store.is_manifest_installed(&manifest).unwrap());
    std::fs::write(directory.join("model.onnx.json"), config).unwrap();
    assert!(store.is_manifest_installed(&manifest).unwrap());
    std::fs::write(
        directory.join("model.onnx.json"),
        b"corrupted configuration",
    )
    .unwrap();
    assert!(!store.is_manifest_installed(&manifest).unwrap());
}

#[test]
fn builds_verified_manifest_from_catalog() {
    let manifest = ModelStore::catalog_manifest("kokoro-82m").unwrap();
    assert_eq!(manifest.artifacts.len(), 1);
    assert_eq!(manifest.artifacts[0].sha256.len(), 64);
    assert_eq!(
        manifest.revision.as_deref(),
        crate::model_catalog::model_revision(
            MODELS
                .iter()
                .find(|model| model.id == "kokoro-82m")
                .unwrap()
        )
        .as_deref()
    );
}

#[test]
fn piper_catalog_manifests_use_one_immutable_snapshot() {
    let snapshot = "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/";
    for (model_id, folder) in [
        ("pt_BR-faber-medium", "pt/pt_BR/faber/medium"),
        ("pt_BR-edresson-low", "pt/pt_BR/edresson/low"),
        ("en_US-lessac-low", "en/en_US/lessac/low"),
    ] {
        let manifest = ModelStore::catalog_manifest(model_id).unwrap();
        assert_eq!(manifest.model_id, model_id);
        assert_eq!(manifest.artifacts.len(), 2);
        for artifact in &manifest.artifacts {
            let extension = if artifact.name.ends_with(".json") {
                "onnx.json"
            } else {
                "onnx"
            };
            assert_eq!(
                artifact.url,
                format!("{snapshot}{folder}/{model_id}.{extension}?download=true")
            );
            assert_eq!(artifact.sha256.len(), 64);
        }
        assert_eq!(manifest.artifacts[0].name, "model.onnx");
        assert_eq!(manifest.artifacts[1].name, "model.onnx.json");
    }
}

#[test]
fn pinned_piper_manifests_preserve_verified_voice_identity() {
    for (model_id, expected_bytes, expected_hashes) in [
        (
            "pt_BR-faber-medium",
            [63_201_294, 4_855],
            [
                "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7",
                "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f",
            ],
        ),
        (
            "pt_BR-edresson-low",
            [63_104_526, 4_168],
            [
                "de4cecee38b30bb1a6378a337af605d59f0c377df702c6a6752870db8991cd84",
                "f138992d2e777d1e3aa0bbb14c2d324307b0f342c1bcf20978765b3bea506c56",
            ],
        ),
        (
            "en_US-lessac-low",
            [63_201_294, 4_882],
            [
                "f7d01dde371555732c4c314111ac79672b1a5ce2fc19266ab42178fd8df7f375",
                "45754dfdebb3b8661c3fc564713772deec6e064feeb5b4e9594857dc7305193a",
            ],
        ),
    ] {
        let manifest = ModelStore::catalog_manifest(model_id).unwrap();
        let descriptor = MODELS.iter().find(|model| model.id == model_id).unwrap();
        for (index, artifact) in manifest.artifacts.iter().enumerate() {
            assert_eq!(artifact.sha256, expected_hashes[index]);
            assert_eq!(descriptor.artifacts[index].bytes, expected_bytes[index]);
        }
    }
}

#[test]
fn rejects_unknown_catalog_model() {
    assert!(matches!(
        ModelStore::catalog_manifest("missing"),
        Err(ModelStoreError::UnknownModel(_))
    ));
}

fn inspection_manifest() -> (ModelManifest, Vec<(&'static str, &'static [u8])>) {
    let artifacts = vec![
        ("model.onnx", b"verified model bytes".as_slice()),
        (
            "model.onnx.json",
            b"{\"audio\":{\"sample_rate\":22050}}".as_slice(),
        ),
    ];
    let manifest = ModelManifest {
        model_id: "inspection-fixture".into(),
        revision: Some("current-revision".into()),
        artifacts: artifacts
            .iter()
            .map(|(name, bytes)| ModelArtifact {
                name: (*name).into(),
                // Inspection is deliberately offline and must never use this URL.
                url: format!("https://127.0.0.1:1/{name}"),
                sha256: hex::encode(Sha256::digest(bytes)),
            })
            .collect(),
    };
    (manifest, artifacts)
}

fn write_inspection_metadata(
    directory: &std::path::Path,
    manifest: &ModelManifest,
    revision: &str,
) {
    let metadata = serde_json::json!({
        "id": manifest.model_id,
        "revision": revision,
        "artifacts": manifest.artifacts.iter().map(|artifact| serde_json::json!({
            "path": artifact.name,
            "sha256": artifact.sha256,
        })).collect::<Vec<_>>(),
    });
    std::fs::write(directory.join("metadata.json"), metadata.to_string()).unwrap();
}

#[test]
fn inspection_distinguishes_missing_corrupted_stale_and_verified_without_network() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let (manifest, artifacts) = inspection_manifest();

    assert_eq!(
        store.inspect_manifest(&manifest).unwrap().state,
        InstalledModelState::Missing
    );
    assert!(!store.is_manifest_installed(&manifest).unwrap());

    let directory = root.path().join(&manifest.model_id);
    std::fs::create_dir_all(&directory).unwrap();
    std::fs::write(directory.join(artifacts[0].0), artifacts[0].1).unwrap();
    assert_eq!(
        store.inspect_manifest(&manifest).unwrap().state,
        InstalledModelState::Missing
    );
    assert!(!store.is_manifest_installed(&manifest).unwrap());

    std::fs::write(directory.join(artifacts[1].0), b"corrupted config").unwrap();
    write_inspection_metadata(&directory, &manifest, "current-revision");
    assert_eq!(
        store.inspect_manifest(&manifest).unwrap().state,
        InstalledModelState::Corrupted
    );
    assert!(!store.is_manifest_installed(&manifest).unwrap());

    let previous_config = b"{\"audio\":{\"sample_rate\":16000}}";
    std::fs::write(directory.join(artifacts[1].0), previous_config).unwrap();
    let stale_metadata = serde_json::json!({
        "id": manifest.model_id,
        "revision": "previous-revision",
        "artifacts": [
            {
                "path": manifest.artifacts[0].name,
                "sha256": manifest.artifacts[0].sha256,
            },
            {
                "path": manifest.artifacts[1].name,
                "sha256": hex::encode(Sha256::digest(previous_config)),
            },
        ],
    });
    std::fs::write(directory.join("metadata.json"), stale_metadata.to_string()).unwrap();
    let stale = store.inspect_manifest(&manifest).unwrap();
    assert_eq!(stale.state, InstalledModelState::StaleRevision);
    assert_eq!(
        stale.verified_revision.as_deref(),
        Some("previous-revision")
    );
    assert_eq!(
        stale.installed_bytes,
        Some(artifacts[0].1.len() as u64 + previous_config.len() as u64)
    );
    assert!(!store.is_manifest_installed(&manifest).unwrap());

    std::fs::write(directory.join(artifacts[1].0), artifacts[1].1).unwrap();
    write_inspection_metadata(&directory, &manifest, "current-revision");
    let verified = store.inspect_manifest(&manifest).unwrap();
    assert_eq!(verified.state, InstalledModelState::Verified);
    assert_eq!(
        verified.verified_revision.as_deref(),
        manifest.revision.as_deref()
    );
    assert_eq!(
        verified.installed_bytes,
        Some(artifacts.iter().map(|(_, bytes)| bytes.len() as u64).sum())
    );
    assert!(store.is_manifest_installed(&manifest).unwrap());
}

#[test]
fn inspection_treats_an_invalid_receipt_as_corrupted_without_exposing_paths() {
    let root = tempfile::tempdir().unwrap();
    let store = ModelStore::new(root.path());
    let (manifest, artifacts) = inspection_manifest();
    let directory = root.path().join(&manifest.model_id);
    std::fs::create_dir_all(&directory).unwrap();
    for (name, bytes) in artifacts {
        std::fs::write(directory.join(name), bytes).unwrap();
    }
    std::fs::write(directory.join("metadata.json"), "not-json").unwrap();

    let inspection = store.inspect_manifest(&manifest).unwrap();
    assert_eq!(inspection.state, InstalledModelState::Corrupted);
    assert_eq!(inspection.verified_revision, None);
    assert_eq!(inspection.installed_bytes, None);
    assert!(store.is_manifest_installed(&manifest).unwrap());
}
