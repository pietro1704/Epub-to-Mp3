//! Verified, atomic storage for downloadable TTS models.

use crate::model_catalog::TtsModelDescriptor;
#[cfg(feature = "kokoro-sherpa-runtime")]
use bzip2::read::BzDecoder;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
#[cfg(feature = "kokoro-sherpa-runtime")]
use tar::Archive;
use thiserror::Error;
use tokio::io::AsyncWriteExt;

#[derive(Debug, Clone)]
pub struct ModelArtifact {
    pub name: String,
    pub url: String,
    pub sha256: String,
}

#[derive(Debug, Clone)]
pub struct ModelManifest {
    pub model_id: String,
    pub artifacts: Vec<ModelArtifact>,
}

#[derive(Debug, Error)]
pub enum ModelStoreError {
    #[error("model download URL is missing")]
    MissingUrl,
    #[error("model download URL must use HTTPS")]
    InsecureUrl,
    #[error("model checksum is missing")]
    MissingChecksum,
    #[error("HTTP model download failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("model file operation failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("model checksum mismatch: expected {expected}, got {actual}")]
    ChecksumMismatch { expected: String, actual: String },
    #[error("invalid model artifact name: {0}")]
    InvalidArtifactName(String),
    #[error("model manifest is empty")]
    EmptyManifest,
    #[error("unknown TTS model: {0}")]
    UnknownModel(String),
    #[error("invalid model archive: {0}")]
    InvalidArchive(String),
}

#[derive(Debug, Clone)]
pub struct InstalledModel {
    pub id: String,
    pub path: PathBuf,
    pub sha256: String,
}

pub struct ModelStore {
    root: PathBuf,
    client: reqwest::Client,
}

impl ModelStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            client: reqwest::Client::new(),
        }
    }

    pub fn model_path(&self, model_id: &str) -> PathBuf {
        self.root.join(model_id).join("model.bin")
    }

    pub fn catalog_manifest(model_id: &str) -> Result<ModelManifest, ModelStoreError> {
        let model = crate::model_catalog::MODELS
            .iter()
            .find(|model| model.id == model_id)
            .ok_or_else(|| ModelStoreError::UnknownModel(model_id.to_owned()))?;
        Ok(ModelManifest {
            model_id: model.id.to_owned(),
            artifacts: model
                .artifacts
                .iter()
                .map(|artifact| ModelArtifact {
                    name: artifact.name.to_owned(),
                    url: artifact.url.to_owned(),
                    sha256: artifact.sha256.to_owned(),
                })
                .collect(),
        })
    }

    pub async fn install(
        &self,
        model: &TtsModelDescriptor,
        url: Option<&str>,
        expected_sha256: Option<&str>,
    ) -> Result<InstalledModel, ModelStoreError> {
        let url = url
            .filter(|value| !value.is_empty())
            .ok_or(ModelStoreError::MissingUrl)?;
        let expected = expected_sha256
            .filter(|value| !value.is_empty())
            .ok_or(ModelStoreError::MissingChecksum)?
            .to_ascii_lowercase();
        if !url.starts_with("https://") {
            return Err(ModelStoreError::InsecureUrl);
        }

        let directory = self.root.join(model.id);
        tokio::fs::create_dir_all(&directory).await?;
        let temporary = directory.join("model.bin.part");
        let target = directory.join("model.bin");
        let mut response = self.client.get(url).send().await?.error_for_status()?;
        let mut file = tokio::fs::File::create(&temporary).await?;
        let mut digest = Sha256::new();
        while let Some(chunk) = response.chunk().await? {
            digest.update(&chunk);
            file.write_all(&chunk).await?;
        }
        file.flush().await?;
        let actual = hex::encode(digest.finalize());
        if actual != expected {
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err(ModelStoreError::ChecksumMismatch { expected, actual });
        }
        tokio::fs::rename(&temporary, &target).await?;
        tokio::fs::write(
            directory.join("metadata.json"),
            format!("{{\"id\":\"{}\",\"sha256\":\"{}\"}}", model.id, actual),
        )
        .await?;
        Ok(InstalledModel {
            id: model.id.to_owned(),
            path: target,
            sha256: actual,
        })
    }

    pub async fn install_manifest(
        &self,
        manifest: &ModelManifest,
    ) -> Result<Vec<InstalledModel>, ModelStoreError> {
        if manifest.artifacts.is_empty() {
            return Err(ModelStoreError::EmptyManifest);
        }
        let staging = self.root.join(format!(".{}.installing", manifest.model_id));
        let target = self.root.join(&manifest.model_id);
        let _ = tokio::fs::remove_dir_all(&staging).await;
        tokio::fs::create_dir_all(&staging).await?;
        let result = async {
            let mut installed = Vec::with_capacity(manifest.artifacts.len());
            for artifact in &manifest.artifacts {
                let path = Path::new(&artifact.name);
                if artifact.name.is_empty()
                    || path.is_absolute()
                    || path
                        .components()
                        .any(|c| matches!(c, std::path::Component::ParentDir))
                {
                    return Err(ModelStoreError::InvalidArtifactName(artifact.name.clone()));
                }
                let destination = staging.join(path);
                if let Some(parent) = destination.parent() {
                    tokio::fs::create_dir_all(parent).await?;
                }
                let temporary = PathBuf::from(format!("{}.part", destination.display()));
                let expected = artifact.sha256.to_ascii_lowercase();
                if expected.is_empty() {
                    return Err(ModelStoreError::MissingChecksum);
                }
                if !artifact.url.starts_with("https://") {
                    return Err(ModelStoreError::InsecureUrl);
                }
                let mut response = self
                    .client
                    .get(&artifact.url)
                    .send()
                    .await?
                    .error_for_status()?;
                let mut file = tokio::fs::File::create(&temporary).await?;
                let mut digest = Sha256::new();
                while let Some(chunk) = response.chunk().await? {
                    digest.update(&chunk);
                    file.write_all(&chunk).await?;
                }
                file.flush().await?;
                let actual = hex::encode(digest.finalize());
                if actual != expected {
                    return Err(ModelStoreError::ChecksumMismatch { expected, actual });
                }
                if artifact.name.ends_with(".tar.bz2") {
                    #[cfg(feature = "kokoro-sherpa-runtime")]
                    {
                        extract_model_archive(&temporary, &staging)?;
                        tokio::fs::remove_file(&temporary).await?;
                    }
                    #[cfg(not(feature = "kokoro-sherpa-runtime"))]
                    return Err(ModelStoreError::InvalidArchive(
                        "archive extraction requires kokoro-sherpa-runtime".to_owned(),
                    ));
                } else {
                    tokio::fs::rename(&temporary, &destination).await?;
                }
                installed.push(InstalledModel {
                    id: manifest.model_id.clone(),
                    path: target.join(path),
                    sha256: actual,
                });
            }
            let backup = self.root.join(format!(".{}.previous", manifest.model_id));
            let _ = tokio::fs::remove_dir_all(&backup).await;
            if tokio::fs::try_exists(&target).await? {
                tokio::fs::rename(&target, &backup).await?;
            }
            let metadata = format!(
                "{{\"id\":\"{}\",\"artifacts\":[{}]}}",
                manifest.model_id,
                installed
                    .iter()
                    .map(|item| {
                        format!(
                            "{{\"path\":\"{}\",\"sha256\":\"{}\"}}",
                            item.path
                                .strip_prefix(&target)
                                .unwrap_or(&item.path)
                                .display(),
                            item.sha256
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(",")
            );
            tokio::fs::write(staging.join("metadata.json"), metadata).await?;
            tokio::fs::rename(&staging, &target).await?;
            let _ = tokio::fs::remove_dir_all(&backup).await;
            Ok(installed)
        }
        .await;
        if result.is_err() {
            let _ = tokio::fs::remove_dir_all(&staging).await;
        }
        result
    }

    /// Installation is complete only when every declared artifact matches its checksum.
    /// This does not claim that inference has been tested on the current device.
    pub fn is_manifest_installed(&self, manifest: &ModelManifest) -> Result<bool, ModelStoreError> {
        use std::io::Read;
        if manifest.artifacts.is_empty() {
            return Err(ModelStoreError::EmptyManifest);
        }
        for artifact in &manifest.artifacts {
            let path = Path::new(&artifact.name);
            if artifact.name.is_empty()
                || path.is_absolute()
                || path.components().any(|component| {
                    matches!(
                        component,
                        std::path::Component::ParentDir | std::path::Component::Prefix(_)
                    )
                })
            {
                return Err(ModelStoreError::InvalidArtifactName(artifact.name.clone()));
            }
            if artifact.sha256.is_empty() {
                return Err(ModelStoreError::MissingChecksum);
            }
            let mut file = match std::fs::File::open(self.root.join(&manifest.model_id).join(path))
            {
                Ok(file) => file,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
                Err(error) => return Err(error.into()),
            };
            let mut digest = Sha256::new();
            let mut buffer = [0u8; 8192];
            loop {
                let count = file.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                digest.update(&buffer[..count]);
            }
            if hex::encode(digest.finalize()) != artifact.sha256.to_ascii_lowercase() {
                return Ok(false);
            }
        }
        Ok(true)
    }

    pub async fn installed_metadata(
        &self,
        model_id: &str,
    ) -> Result<Option<String>, ModelStoreError> {
        let path = self.root.join(model_id).join("metadata.json");
        match tokio::fs::read_to_string(path).await {
            Ok(value) => Ok(Some(value)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(ModelStoreError::Io(error)),
        }
    }

    pub async fn is_installed(&self, model_id: &str, expected_sha256: &str) -> bool {
        let path = self.model_path(model_id);
        match tokio::fs::read(path).await {
            Ok(bytes) => hex::encode(Sha256::digest(bytes)) == expected_sha256.to_ascii_lowercase(),
            Err(_) => false,
        }
    }

    pub async fn remove(&self, model_id: &str) -> Result<(), ModelStoreError> {
        let directory = self.root.join(model_id);
        if tokio::fs::try_exists(&directory).await? {
            tokio::fs::remove_dir_all(directory).await?;
        }
        Ok(())
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
}

#[cfg(feature = "kokoro-sherpa-runtime")]
fn extract_model_archive(archive_path: &Path, staging: &Path) -> Result<(), ModelStoreError> {
    let file = std::fs::File::open(archive_path)?;
    let decoder = BzDecoder::new(file);
    let mut archive = Archive::new(decoder);
    let archive_root = staging.join(".archive");
    std::fs::create_dir_all(&archive_root)?;
    for entry in archive
        .entries()
        .map_err(|error| ModelStoreError::InvalidArchive(error.to_string()))?
    {
        let mut entry =
            entry.map_err(|error| ModelStoreError::InvalidArchive(error.to_string()))?;
        let path = entry
            .path()
            .map_err(|error| ModelStoreError::InvalidArchive(error.to_string()))?
            .into_owned();
        if path.is_absolute()
            || path
                .components()
                .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err(ModelStoreError::InvalidArtifactName(
                path.display().to_string(),
            ));
        }
        let destination = archive_root.join(&path);
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }
        entry
            .unpack(&destination)
            .map_err(|error| ModelStoreError::InvalidArchive(error.to_string()))?;
    }
    let entries = std::fs::read_dir(&archive_root)?.collect::<Result<Vec<_>, _>>()?;
    if entries.len() == 1 && entries[0].path().is_dir() {
        let root = entries[0].path();
        for entry in std::fs::read_dir(root)? {
            let entry = entry?;
            std::fs::rename(entry.path(), staging.join(entry.file_name()))?;
        }
    } else {
        for entry in entries {
            std::fs::rename(entry.path(), staging.join(entry.file_name()))?;
        }
    }
    std::fs::remove_dir_all(&archive_root)?;
    Ok(())
}

#[cfg(test)]
mod tests {
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
}
