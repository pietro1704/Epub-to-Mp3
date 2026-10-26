//! Reconnectable verification and atomic publication for externally downloaded models.

use super::{InstalledModel, ModelManifest, ModelStore, ModelStoreError};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

#[path = "model_install_operation_types.rs"]
mod operation_types;
pub use operation_types::{
    ModelInstallArtifactPlan, ModelInstallEvent, ModelInstallFailure, ModelInstallPlan,
    ModelInstallStage,
};

#[path = "model_install_operation_files.rs"]
pub(super) mod operation_files;
use operation_files::{
    hash_file, publish_directory, remove_owned_directory, verified_file, write_atomic,
};

#[path = "model_install_operation_preflight.rs"]
mod operation_preflight;
#[cfg(test)]
use operation_preflight::INSTALL_SPACE_SAFETY_BYTES;

pub struct ModelInstallOperation {
    store: ModelStore,
    manifest: ModelManifest,
    artifacts: Vec<ModelInstallArtifactPlan>,
    operation_id: String,
    staging: PathBuf,
    inbox: PathBuf,
    available_bytes: u64,
    required_bytes: u64,
    progress: Vec<u64>,
    cancellation: Arc<AtomicBool>,
    event: ModelInstallEvent,
}

impl ModelInstallOperation {
    pub fn plan(&self) -> ModelInstallPlan {
        ModelInstallPlan {
            version: 1,
            operation_id: self.operation_id.clone(),
            model_id: self.manifest.model_id.clone(),
            revision: self.manifest.revision.clone(),
            required_bytes: self.required_bytes,
            available_bytes: self.available_bytes,
            ready: self.event.failure.is_none(),
            artifacts: self.artifacts.clone(),
            event: self.event.clone(),
        }
    }

    pub fn event(&self) -> &ModelInstallEvent {
        &self.event
    }

    pub fn record_download_progress(
        &mut self,
        artifact_index: usize,
        reported_bytes: u64,
    ) -> Result<&ModelInstallEvent, ModelStoreError> {
        self.ensure_active()?;
        let artifact = self
            .artifacts
            .get(artifact_index)
            .ok_or(ModelStoreError::InvalidDownloadedArtifact(artifact_index))?;
        let previous = self.progress[artifact_index];
        if reported_bytes < previous {
            return Err(ModelStoreError::ProgressRegressed {
                previous_bytes: previous,
                reported_bytes,
            });
        }
        self.progress[artifact_index] = reported_bytes.min(artifact.expected_bytes);
        self.advance(ModelInstallStage::Downloading, Some(artifact_index), None);
        Ok(&self.event)
    }

    pub fn accept_download(
        &mut self,
        artifact_index: usize,
        source: &Path,
    ) -> Result<&ModelInstallEvent, ModelStoreError> {
        self.accept_download_with_checkpoints(artifact_index, source, |_| {})
    }

    fn accept_download_with_checkpoints(
        &mut self,
        artifact_index: usize,
        source: &Path,
        mut checkpoint: impl FnMut(usize),
    ) -> Result<&ModelInstallEvent, ModelStoreError> {
        self.ensure_active()?;
        let artifact = self
            .artifacts
            .get(artifact_index)
            .cloned()
            .ok_or(ModelStoreError::InvalidDownloadedArtifact(artifact_index))?;
        if source != artifact.inbox_path {
            return Err(ModelStoreError::InvalidDownloadedArtifact(artifact_index));
        }
        self.advance(ModelInstallStage::Verifying, Some(artifact_index), None);
        let verified = verified_file(
            source,
            artifact.expected_bytes,
            &artifact.sha256,
            &self.cancellation,
            |chunk| checkpoint(chunk),
        );
        match verified {
            Ok(true) => {}
            Ok(false) => {
                let actual = match hash_file(source, &self.cancellation, |_| {}) {
                    Ok(actual) => actual,
                    Err(error) => {
                        if matches!(error, ModelStoreError::Cancelled) {
                            self.cancel()?;
                        } else {
                            self.fail_and_cleanup("verification_failed", error.to_string())?;
                        }
                        return Err(error);
                    }
                };
                let error = ModelStoreError::ChecksumMismatch {
                    expected: artifact.sha256,
                    actual,
                };
                self.fail_and_cleanup("checksum_mismatch", error.to_string())?;
                return Err(error);
            }
            Err(error) => {
                if matches!(error, ModelStoreError::Cancelled) {
                    self.cancel()?;
                } else {
                    self.fail_and_cleanup("verification_failed", error.to_string())?;
                }
                return Err(error);
            }
        }
        self.ensure_active()?;
        let destination = self.staging.join(&artifact.name);
        let staging_result = (|| -> Result<(), ModelStoreError> {
            if let Some(parent) = destination.parent() {
                std::fs::create_dir_all(parent)?;
            }
            if destination.exists() {
                std::fs::remove_file(&destination)?;
            }
            std::fs::rename(source, destination)?;
            Ok(())
        })();
        if let Err(error) = staging_result {
            self.fail_and_cleanup("staging_failed", error.to_string())?;
            return Err(error);
        }
        self.artifacts[artifact_index].accepted = true;
        self.progress[artifact_index] = artifact.expected_bytes;
        self.advance(ModelInstallStage::Downloading, Some(artifact_index), None);
        Ok(&self.event)
    }

    pub fn publish(&mut self) -> Result<Vec<InstalledModel>, ModelStoreError> {
        self.ensure_active()?;
        for artifact in &self.artifacts {
            if !artifact.accepted {
                return Err(ModelStoreError::ArtifactPending(artifact.index));
            }
        }
        self.advance(ModelInstallStage::Publishing, None, None);
        self.ensure_active()?;
        let installed = self
            .artifacts
            .iter()
            .map(|artifact| InstalledModel {
                id: self.manifest.model_id.clone(),
                path: self
                    .store
                    .root()
                    .join(&self.manifest.model_id)
                    .join(&artifact.name),
                sha256: artifact.sha256.clone(),
            })
            .collect::<Vec<_>>();
        let metadata = serde_json::json!({
            "id": self.manifest.model_id,
            "revision": self.manifest.revision,
            "artifacts": self.artifacts.iter().map(|artifact| serde_json::json!({
                "path": artifact.name,
                "sha256": artifact.sha256,
            })).collect::<Vec<_>>(),
        });
        let publication = (|| -> Result<(), ModelStoreError> {
            write_atomic(
                &self.staging.join("metadata.json"),
                metadata.to_string().as_bytes(),
            )?;
            let _ = std::fs::remove_file(self.staging.join(".operation.json"));
            self.ensure_active()?;
            remove_owned_directory(&self.inbox)?;
            publish_directory(
                &self.staging,
                &self.store.root().join(&self.manifest.model_id),
                &self
                    .store
                    .root()
                    .join(format!(".{}.previous", self.manifest.model_id)),
            )
        })();
        if let Err(error) = publication {
            if matches!(error, ModelStoreError::Cancelled) {
                self.cancel()?;
            } else {
                self.fail_and_cleanup("publication_failed", error.to_string())?;
            }
            return Err(error);
        }
        self.advance(ModelInstallStage::Completed, None, None);
        Ok(installed)
    }

    pub fn cancel(&mut self) -> Result<(), ModelStoreError> {
        if self.event.stage.is_terminal() {
            return Ok(());
        }
        self.cancellation.store(true, Ordering::Release);
        let staging_cleanup = remove_owned_directory(&self.staging);
        let inbox_cleanup = remove_owned_directory(&self.inbox);
        self.advance(
            ModelInstallStage::Cancelled,
            None,
            Some(ModelInstallFailure {
                kind: "cancelled".into(),
                message: ModelStoreError::Cancelled.to_string(),
                required_bytes: None,
                available_bytes: None,
            }),
        );
        staging_cleanup.and(inbox_cleanup)
    }

    pub fn fail(&mut self, kind: &str, message: &str) -> Result<(), ModelStoreError> {
        self.fail_and_cleanup(kind, message.to_owned())
    }

    fn fail_and_cleanup(&mut self, kind: &str, message: String) -> Result<(), ModelStoreError> {
        if self.event.stage.is_terminal() {
            return Err(ModelStoreError::OperationFinished);
        }
        let staging_cleanup = remove_owned_directory(&self.staging);
        let inbox_cleanup = remove_owned_directory(&self.inbox);
        self.advance(
            ModelInstallStage::Failed,
            None,
            Some(ModelInstallFailure {
                kind: kind.to_owned(),
                message,
                required_bytes: None,
                available_bytes: None,
            }),
        );
        staging_cleanup.and(inbox_cleanup)
    }

    fn ensure_active(&self) -> Result<(), ModelStoreError> {
        if self.cancellation.load(Ordering::Acquire) {
            Err(ModelStoreError::Cancelled)
        } else if self.event.stage.is_terminal() {
            Err(ModelStoreError::OperationFinished)
        } else {
            Ok(())
        }
    }

    fn advance(
        &mut self,
        stage: ModelInstallStage,
        artifact_index: Option<usize>,
        failure: Option<ModelInstallFailure>,
    ) {
        if self.event.stage.is_terminal() {
            return;
        }
        self.event.sequence += 1;
        if stage >= self.event.stage
            || matches!(
                stage,
                ModelInstallStage::Completed
                    | ModelInstallStage::Cancelled
                    | ModelInstallStage::Failed
            )
        {
            self.event.stage = stage;
        }
        self.event.artifact_index = artifact_index;
        self.event.bytes_completed = self
            .artifacts
            .iter()
            .enumerate()
            .map(|(index, artifact)| {
                if artifact.accepted {
                    artifact.expected_bytes
                } else {
                    self.progress[index]
                }
            })
            .sum();
        self.event.failure = failure;
    }
}

#[cfg(test)]
#[path = "model_install_operation_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "model_install_operation_lifecycle_tests.rs"]
mod lifecycle_tests;
