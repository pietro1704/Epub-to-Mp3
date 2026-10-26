use super::ModelStoreError;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::Read,
    path::{Component, Path},
    sync::atomic::{AtomicBool, Ordering},
};

#[derive(Debug, Serialize, Deserialize)]
pub(super) struct OperationReceipt {
    pub(super) version: u32,
    pub(super) operation_id: String,
    pub(super) model_id: String,
    pub(super) revision: Option<String>,
}

pub(super) fn validate_artifact_name(name: &str) -> Result<(), ModelStoreError> {
    let path = Path::new(name);
    if name.is_empty()
        || path.is_absolute()
        || !path
            .components()
            .all(|component| matches!(component, std::path::Component::Normal(_)))
    {
        return Err(ModelStoreError::InvalidArtifactName(name.to_owned()));
    }
    Ok(())
}

pub(in crate::model_store) fn validate_model_id(model_id: &str) -> Result<(), ModelStoreError> {
    let mut components = Path::new(model_id).components();
    if model_id.is_empty()
        || !matches!(components.next(), Some(Component::Normal(_)))
        || components.next().is_some()
    {
        return Err(ModelStoreError::InvalidModelId(model_id.to_owned()));
    }
    Ok(())
}

pub(super) fn validate_artifact_contract(
    url: &str,
    sha256: &str,
    expected_bytes: u64,
) -> Result<(), ModelStoreError> {
    if !url.starts_with("https://") {
        return Err(ModelStoreError::InsecureUrl);
    }
    if sha256.is_empty() {
        return Err(ModelStoreError::MissingChecksum);
    }
    if sha256.len() != 64 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ModelStoreError::InvalidArchive(
            "artifact checksum must be 64 hexadecimal characters".into(),
        ));
    }
    if expected_bytes == 0 {
        return Err(ModelStoreError::InvalidArchive(
            "artifact byte count must be positive".into(),
        ));
    }
    Ok(())
}

pub(super) fn ensure_owned_directory(path: &Path) -> Result<(), ModelStoreError> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err(ModelStoreError::InvalidArchive(format!(
                "owned installation path is not a directory: {}",
                path.display()
            )))
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(path)?;
            Ok(())
        }
        Err(error) => Err(error.into()),
    }
}

pub(super) fn matching_receipt(
    staging: &Path,
    model_id: &str,
    revision: &Option<String>,
) -> Option<OperationReceipt> {
    let staging_metadata = std::fs::symlink_metadata(staging).ok()?;
    if !staging_metadata.is_dir() || staging_metadata.file_type().is_symlink() {
        return None;
    }
    let receipt_path = staging.join(".operation.json");
    let receipt_metadata = std::fs::symlink_metadata(&receipt_path).ok()?;
    if !receipt_metadata.is_file() || receipt_metadata.file_type().is_symlink() {
        return None;
    }
    std::fs::read(receipt_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<OperationReceipt>(&bytes).ok())
        .filter(|receipt| {
            receipt.version == 2
                && !receipt.operation_id.is_empty()
                && receipt.model_id == model_id
                && &receipt.revision == revision
        })
}

pub(super) fn write_receipt(
    staging: &Path,
    receipt: &OperationReceipt,
) -> Result<(), ModelStoreError> {
    let bytes = serde_json::to_vec(receipt)
        .map_err(|error| ModelStoreError::InvalidArchive(error.to_string()))?;
    write_atomic(&staging.join(".operation.json"), &bytes)
}

pub(super) fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), ModelStoreError> {
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, bytes)?;
    std::fs::rename(temporary, path)?;
    Ok(())
}

pub(super) fn verified_file(
    path: &Path,
    expected_bytes: u64,
    expected_sha256: &str,
    cancellation: &AtomicBool,
    checkpoint: impl FnMut(usize),
) -> Result<bool, ModelStoreError> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() != expected_bytes
    {
        return Ok(false);
    }
    Ok(hash_file(path, cancellation, checkpoint)?.eq_ignore_ascii_case(expected_sha256))
}

pub(super) fn hash_file(
    path: &Path,
    cancellation: &AtomicBool,
    mut checkpoint: impl FnMut(usize),
) -> Result<String, ModelStoreError> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    let mut chunk = 0usize;
    loop {
        checkpoint(chunk);
        if cancellation.load(Ordering::Acquire) {
            return Err(ModelStoreError::Cancelled);
        }
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
        chunk += 1;
    }
    checkpoint(chunk);
    if cancellation.load(Ordering::Acquire) {
        return Err(ModelStoreError::Cancelled);
    }
    Ok(hex::encode(digest.finalize()))
}

pub(super) fn publish_directory(
    staging: &Path,
    target: &Path,
    backup: &Path,
) -> Result<(), ModelStoreError> {
    restore_previous_target(target, backup)?;
    remove_owned_directory(backup)?;
    let had_target = std::fs::symlink_metadata(target).is_ok();
    if had_target {
        std::fs::rename(target, backup)?;
    }
    if let Err(error) = std::fs::rename(staging, target) {
        if had_target && backup.exists() {
            if let Err(rollback) = std::fs::rename(backup, target) {
                return Err(ModelStoreError::InvalidArchive(format!(
                    "publication failed ({error}); previous model remains at {} because rollback failed ({rollback})",
                    backup.display()
                )));
            }
        }
        return Err(error.into());
    }
    let _ = remove_owned_directory(backup);
    Ok(())
}

pub(super) fn restore_previous_target(target: &Path, backup: &Path) -> Result<(), ModelStoreError> {
    let backup_metadata = match std::fs::symlink_metadata(backup) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if !backup_metadata.is_dir() || backup_metadata.file_type().is_symlink() {
        return remove_owned_directory(backup);
    }
    if std::fs::symlink_metadata(target).is_err() {
        std::fs::rename(backup, target)?;
    }
    Ok(())
}

pub(in crate::model_store) fn remove_owned_directory(path: &Path) -> Result<(), ModelStoreError> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    let removal = if metadata.is_dir() && !metadata.file_type().is_symlink() {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    };
    match removal {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}
