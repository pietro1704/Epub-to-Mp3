use super::{
    operation_files::{
        ensure_owned_directory, matching_receipt, remove_owned_directory, restore_previous_target,
        validate_artifact_contract, validate_artifact_name, validate_model_id, verified_file,
        write_receipt, OperationReceipt,
    },
    ModelInstallArtifactPlan, ModelInstallEvent, ModelInstallFailure, ModelInstallOperation,
    ModelInstallStage,
};
use crate::model_store::{ModelManifest, ModelStore, ModelStoreError};
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Copy)]
enum BeginMode {
    StartOrResume,
    ResumeOnly,
}

static OPERATION_SEQUENCE: AtomicU64 = AtomicU64::new(0);
pub(super) const INSTALL_SPACE_SAFETY_BYTES: u64 = 16 * 1024 * 1024;

impl ModelInstallOperation {
    pub fn begin_catalog(
        root: impl Into<PathBuf>,
        model_id: &str,
        available_bytes: u64,
        cancellation: Arc<AtomicBool>,
    ) -> Result<Self, ModelStoreError> {
        Self::catalog_operation(
            root.into(),
            model_id,
            available_bytes,
            cancellation,
            BeginMode::StartOrResume,
        )
        .and_then(|operation| operation.ok_or(ModelStoreError::NoPendingInstall))
    }

    pub fn recover_catalog(
        root: impl Into<PathBuf>,
        model_id: &str,
        available_bytes: u64,
        cancellation: Arc<AtomicBool>,
    ) -> Result<Option<Self>, ModelStoreError> {
        Self::catalog_operation(
            root.into(),
            model_id,
            available_bytes,
            cancellation,
            BeginMode::ResumeOnly,
        )
    }

    fn catalog_operation(
        root: PathBuf,
        model_id: &str,
        available_bytes: u64,
        cancellation: Arc<AtomicBool>,
        mode: BeginMode,
    ) -> Result<Option<Self>, ModelStoreError> {
        let descriptor = crate::model_catalog::MODELS
            .iter()
            .find(|model| model.id == model_id)
            .ok_or_else(|| ModelStoreError::UnknownModel(model_id.to_owned()))?;
        let manifest = ModelStore::catalog_manifest(model_id)?;
        Self::begin(
            root,
            manifest,
            descriptor
                .artifacts
                .iter()
                .map(|artifact| artifact.bytes)
                .collect(),
            available_bytes,
            cancellation,
            mode,
        )
        .map(Some)
        .or_else(|error| match error {
            ModelStoreError::NoPendingInstall => Ok(None),
            other => Err(other),
        })
    }

    fn begin(
        root: PathBuf,
        manifest: ModelManifest,
        expected_bytes: Vec<u64>,
        available_bytes: u64,
        cancellation: Arc<AtomicBool>,
        mode: BeginMode,
    ) -> Result<Self, ModelStoreError> {
        validate_preflight_inputs(&manifest, &expected_bytes, &cancellation)?;
        let artifact_count = manifest.artifacts.len();
        let model_id = manifest.model_id.clone();
        let staging = root.join(format!(".{model_id}.installing"));
        let inbox = root.join(format!(".{model_id}.downloads"));
        restore_previous_target(
            &root.join(&model_id),
            &root.join(format!(".{model_id}.previous")),
        )?;

        let previous_receipt = matching_receipt(&staging, &model_id, &manifest.revision);
        if previous_receipt.is_none() {
            remove_owned_directory(&staging)?;
            remove_owned_directory(&inbox)?;
            if matches!(mode, BeginMode::ResumeOnly) {
                return Err(ModelStoreError::NoPendingInstall);
            }
        }
        let operation_id = previous_receipt
            .as_ref()
            .map(|receipt| receipt.operation_id.clone())
            .unwrap_or_else(|| new_operation_id(&model_id, manifest.revision.as_deref()));
        let receipt = OperationReceipt {
            version: 2,
            operation_id: operation_id.clone(),
            model_id: model_id.to_owned(),
            revision: manifest.revision.clone(),
        };

        let (artifacts, outstanding_bytes) =
            prepare_artifact_plans(&manifest, expected_bytes, &staging, &inbox, &cancellation)?;
        let required_bytes = required_capacity(outstanding_bytes)?;
        let failure = (available_bytes < required_bytes).then(|| ModelInstallFailure {
            kind: "insufficient_space".into(),
            message: ModelStoreError::InsufficientSpace {
                required_bytes,
                available_bytes,
            }
            .to_string(),
            required_bytes: Some(required_bytes),
            available_bytes: Some(available_bytes),
        });
        let ready = failure.is_none();
        if ready {
            ensure_owned_directory(&staging)?;
            ensure_owned_directory(&inbox)?;
            write_receipt(&staging, &receipt)?;
        }
        let event = ModelInstallEvent {
            sequence: 0,
            operation_id: operation_id.clone(),
            model_id: model_id.to_owned(),
            stage: if ready {
                ModelInstallStage::Preflight
            } else {
                ModelInstallStage::Failed
            },
            artifact_index: None,
            bytes_completed: artifacts
                .iter()
                .filter(|artifact| artifact.accepted)
                .map(|artifact| artifact.expected_bytes)
                .sum(),
            bytes_total: artifacts
                .iter()
                .map(|artifact| artifact.expected_bytes)
                .sum(),
            failure,
        };
        Ok(Self {
            store: ModelStore::new(root),
            manifest,
            artifacts,
            operation_id,
            staging,
            inbox,
            available_bytes,
            required_bytes,
            progress: vec![0; artifact_count],
            cancellation,
            event,
        })
    }

    #[cfg(test)]
    pub(super) fn begin_fixture(
        root: impl Into<PathBuf>,
        manifest: ModelManifest,
        expected_bytes: Vec<u64>,
        available_bytes: u64,
        cancellation: Arc<AtomicBool>,
    ) -> Result<Self, ModelStoreError> {
        Self::begin(
            root.into(),
            manifest,
            expected_bytes,
            available_bytes,
            cancellation,
            BeginMode::StartOrResume,
        )
    }

    #[cfg(test)]
    pub(super) fn recover_fixture(
        root: impl Into<PathBuf>,
        manifest: ModelManifest,
        expected_bytes: Vec<u64>,
        available_bytes: u64,
        cancellation: Arc<AtomicBool>,
    ) -> Result<Option<Self>, ModelStoreError> {
        Self::begin(
            root.into(),
            manifest,
            expected_bytes,
            available_bytes,
            cancellation,
            BeginMode::ResumeOnly,
        )
        .map(Some)
        .or_else(|error| match error {
            ModelStoreError::NoPendingInstall => Ok(None),
            other => Err(other),
        })
    }
}

fn validate_preflight_inputs(
    manifest: &ModelManifest,
    expected_bytes: &[u64],
    cancellation: &AtomicBool,
) -> Result<(), ModelStoreError> {
    if cancellation.load(Ordering::Acquire) {
        return Err(ModelStoreError::Cancelled);
    }
    if manifest.artifacts.is_empty() {
        return Err(ModelStoreError::EmptyManifest);
    }
    if manifest.artifacts.len() != expected_bytes.len() {
        return Err(ModelStoreError::InvalidArchive(
            "artifact byte count does not match the manifest".into(),
        ));
    }
    validate_model_id(&manifest.model_id)
}

fn prepare_artifact_plans(
    manifest: &ModelManifest,
    expected_bytes: Vec<u64>,
    staging: &std::path::Path,
    inbox: &std::path::Path,
    cancellation: &AtomicBool,
) -> Result<(Vec<ModelInstallArtifactPlan>, u64), ModelStoreError> {
    let mut artifacts = Vec::with_capacity(manifest.artifacts.len());
    let mut outstanding_bytes = 0u64;
    for (index, (artifact, artifact_bytes)) in
        manifest.artifacts.iter().zip(expected_bytes).enumerate()
    {
        validate_artifact_name(&artifact.name)?;
        validate_artifact_contract(&artifact.url, &artifact.sha256, artifact_bytes)?;
        let accepted = verified_file(
            &staging.join(&artifact.name),
            artifact_bytes,
            &artifact.sha256,
            cancellation,
            |_| {},
        )?;
        if !accepted {
            outstanding_bytes = outstanding_bytes
                .checked_add(artifact_bytes)
                .ok_or_else(|| {
                    ModelStoreError::InvalidArchive("artifact byte count overflow".into())
                })?;
        }
        artifacts.push(ModelInstallArtifactPlan {
            index,
            name: artifact.name.clone(),
            url: artifact.url.clone(),
            sha256: artifact.sha256.clone(),
            expected_bytes: artifact_bytes,
            inbox_path: inbox.join(format!("{index}.download")),
            accepted,
        });
    }
    Ok((artifacts, outstanding_bytes))
}

fn required_capacity(outstanding_bytes: u64) -> Result<u64, ModelStoreError> {
    if outstanding_bytes == 0 {
        return Ok(0);
    }
    // Download temp files, the owned inbox and staging stay on one volume and
    // are moved rather than copied. The existing target already consumes space
    // before this capacity reading; publication only renames it for rollback.
    outstanding_bytes
        .checked_add(INSTALL_SPACE_SAFETY_BYTES)
        .ok_or_else(|| ModelStoreError::InvalidArchive("installation byte count overflow".into()))
}

fn new_operation_id(model_id: &str, revision: Option<&str>) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let input = format!(
        "{model_id}:{}:{now}:{}:{}",
        revision.unwrap_or("unversioned"),
        std::process::id(),
        OPERATION_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    );
    hex::encode(Sha256::digest(input))[..24].to_owned()
}
