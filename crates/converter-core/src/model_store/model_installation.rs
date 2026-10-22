//! Model installation and installed-state verification share one transaction owner.
#[cfg(feature = "kokoro-sherpa-runtime")]
use super::model_archive_installation::extract_model_archive;
use super::{InstalledModel, ModelArtifact, ModelManifest, ModelStoreError};
use crate::model_catalog::TtsModelDescriptor;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use tokio::io::AsyncWriteExt;

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
