//! Verified, atomic storage for downloadable TTS models.

use crate::model_catalog::TtsModelDescriptor;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
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
                tokio::fs::rename(&temporary, &destination).await?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model_catalog::MODELS;

    #[tokio::test]
    async fn rejects_unverified_install_before_network_access() {
        let store = ModelStore::new(std::env::temp_dir().join("epubtomp3-model-store-test"));
        let error = store.install(&MODELS[0], None, None).await.unwrap_err();
        assert!(matches!(error, ModelStoreError::MissingUrl));
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

    #[test]
    fn builds_verified_manifest_from_catalog() {
        let manifest = ModelStore::catalog_manifest("kokoro-82m").unwrap();
        assert_eq!(manifest.artifacts.len(), 5);
        assert_eq!(manifest.artifacts[0].sha256.len(), 64);
    }

    #[test]
    fn rejects_unknown_catalog_model() {
        assert!(matches!(
            ModelStore::catalog_manifest("missing"),
            Err(ModelStoreError::UnknownModel(_))
        ));
    }
}
