//! Verified, atomic storage for downloadable TTS models.

use crate::model_catalog::TtsModelDescriptor;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use thiserror::Error;
use tokio::io::AsyncWriteExt;

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
}
