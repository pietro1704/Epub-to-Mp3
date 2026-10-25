//! Offline inspection of installed model identity and artifact integrity.

use super::{ModelManifest, ModelStore, ModelStoreError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    fs::File,
    io::Read,
    path::Path,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InstalledModelState {
    Missing,
    Corrupted,
    StaleRevision,
    Verified,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledModelInspection {
    pub state: InstalledModelState,
    pub verified_revision: Option<String>,
    pub installed_bytes: Option<u64>,
}

impl InstalledModelInspection {
    fn state(state: InstalledModelState) -> Self {
        Self {
            state,
            verified_revision: None,
            installed_bytes: None,
        }
    }
}

#[derive(Debug, Deserialize)]
struct InstallationReceipt {
    id: String,
    revision: Option<String>,
    artifacts: Vec<ReceiptArtifact>,
}

#[derive(Debug, Deserialize)]
struct ReceiptArtifact {
    path: String,
    sha256: String,
}

impl ModelStore {
    /// Rehashes every declared artifact and validates its installation receipt.
    ///
    /// Inspection performs filesystem reads only. It never contacts artifact URLs,
    /// changes the active selection, or exposes inspected filesystem paths.
    pub fn inspect_manifest(
        &self,
        manifest: &ModelManifest,
    ) -> Result<InstalledModelInspection, ModelStoreError> {
        validate_manifest(manifest)?;
        let directory = self.root().join(&manifest.model_id);
        let directory_metadata = match std::fs::symlink_metadata(&directory) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(InstalledModelInspection::state(
                    InstalledModelState::Missing,
                ));
            }
            Err(_) => {
                return Ok(InstalledModelInspection::state(
                    InstalledModelState::Corrupted,
                ));
            }
        };
        if directory_metadata.file_type().is_symlink() || !directory_metadata.is_dir() {
            return Ok(InstalledModelInspection::state(
                InstalledModelState::Corrupted,
            ));
        }

        let receipt = match read_receipt(&directory) {
            ReceiptRead::Missing => {
                return Ok(
                    match inspect_artifacts(
                        &directory,
                        manifest
                            .artifacts
                            .iter()
                            .map(|artifact| (artifact.name.as_str(), artifact.sha256.as_str())),
                    ) {
                        ArtifactInspection::Missing => {
                            InstalledModelInspection::state(InstalledModelState::Missing)
                        }
                        ArtifactInspection::Corrupted | ArtifactInspection::Verified(_) => {
                            InstalledModelInspection::state(InstalledModelState::Corrupted)
                        }
                    },
                );
            }
            ReceiptRead::Invalid => {
                return Ok(InstalledModelInspection::state(
                    InstalledModelState::Corrupted,
                ));
            }
            ReceiptRead::Receipt(receipt) => receipt,
        };
        if receipt.id != manifest.model_id {
            return Ok(InstalledModelInspection::state(
                InstalledModelState::Corrupted,
            ));
        }
        let receipt_artifacts = match validated_receipt_artifacts(&receipt) {
            Some(artifacts) => artifacts,
            None => {
                return Ok(InstalledModelInspection::state(
                    InstalledModelState::Corrupted,
                ));
            }
        };
        if receipt.revision != manifest.revision {
            return Ok(
                match inspect_artifacts(
                    &directory,
                    receipt_artifacts
                        .iter()
                        .map(|(path, sha256)| (*path, sha256.as_str())),
                ) {
                    ArtifactInspection::Missing => {
                        InstalledModelInspection::state(InstalledModelState::Missing)
                    }
                    ArtifactInspection::Corrupted => {
                        InstalledModelInspection::state(InstalledModelState::Corrupted)
                    }
                    ArtifactInspection::Verified(installed_bytes) => InstalledModelInspection {
                        state: InstalledModelState::StaleRevision,
                        verified_revision: receipt.revision,
                        installed_bytes: Some(installed_bytes),
                    },
                },
            );
        }
        if !receipt_matches_manifest(&receipt_artifacts, manifest) {
            return Ok(InstalledModelInspection::state(
                InstalledModelState::Corrupted,
            ));
        }

        Ok(
            match inspect_artifacts(
                &directory,
                manifest
                    .artifacts
                    .iter()
                    .map(|artifact| (artifact.name.as_str(), artifact.sha256.as_str())),
            ) {
                ArtifactInspection::Missing => {
                    InstalledModelInspection::state(InstalledModelState::Missing)
                }
                ArtifactInspection::Corrupted => {
                    InstalledModelInspection::state(InstalledModelState::Corrupted)
                }
                ArtifactInspection::Verified(installed_bytes) => InstalledModelInspection {
                    state: InstalledModelState::Verified,
                    verified_revision: manifest.revision.clone(),
                    installed_bytes: Some(installed_bytes),
                },
            },
        )
    }
}

fn validate_manifest(manifest: &ModelManifest) -> Result<(), ModelStoreError> {
    if manifest.artifacts.is_empty() {
        return Err(ModelStoreError::EmptyManifest);
    }
    let model_id = Path::new(&manifest.model_id);
    if manifest.model_id.is_empty()
        || model_id.is_absolute()
        || model_id.components().count() != 1
        || !model_id
            .components()
            .all(|component| matches!(component, std::path::Component::Normal(_)))
    {
        return Err(ModelStoreError::InvalidModelId(manifest.model_id.clone()));
    }
    let mut artifact_names = HashSet::new();
    for artifact in &manifest.artifacts {
        let path = Path::new(&artifact.name);
        if artifact.name.is_empty()
            || path.is_absolute()
            || !path
                .components()
                .all(|component| matches!(component, std::path::Component::Normal(_)))
            || !artifact_names.insert(artifact.name.as_str())
        {
            return Err(ModelStoreError::InvalidArtifactName(artifact.name.clone()));
        }
        if artifact.sha256.len() != 64
            || !artifact.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(ModelStoreError::MissingChecksum);
        }
    }
    Ok(())
}

enum ScopedFile {
    Missing,
    Invalid,
    File(File),
}

enum ArtifactInspection {
    Missing,
    Corrupted,
    Verified(u64),
}

fn inspect_artifacts<'a>(
    root: &Path,
    artifacts: impl Iterator<Item = (&'a str, &'a str)>,
) -> ArtifactInspection {
    let mut installed_bytes = 0u64;
    for (name, expected_sha256) in artifacts {
        let file = match open_scoped_file(root, Path::new(name)) {
            ScopedFile::Missing => return ArtifactInspection::Missing,
            ScopedFile::Invalid => return ArtifactInspection::Corrupted,
            ScopedFile::File(file) => file,
        };
        let (actual_sha256, bytes) = match hash_file(file) {
            Ok(value) => value,
            Err(_) => return ArtifactInspection::Corrupted,
        };
        if actual_sha256 != expected_sha256.to_ascii_lowercase() {
            return ArtifactInspection::Corrupted;
        }
        installed_bytes = match installed_bytes.checked_add(bytes) {
            Some(total) => total,
            None => return ArtifactInspection::Corrupted,
        };
    }
    ArtifactInspection::Verified(installed_bytes)
}

fn open_scoped_file(root: &Path, relative: &Path) -> ScopedFile {
    let components = relative.components().collect::<Vec<_>>();
    let mut current = root.to_path_buf();
    for (index, component) in components.iter().enumerate() {
        current.push(component.as_os_str());
        let metadata = match std::fs::symlink_metadata(&current) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return ScopedFile::Missing;
            }
            Err(_) => return ScopedFile::Invalid,
        };
        let final_component = index + 1 == components.len();
        if metadata.file_type().is_symlink()
            || (final_component && !metadata.is_file())
            || (!final_component && !metadata.is_dir())
        {
            return ScopedFile::Invalid;
        }
    }
    match File::open(current) {
        Ok(file) => ScopedFile::File(file),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => ScopedFile::Missing,
        Err(_) => ScopedFile::Invalid,
    }
}

fn hash_file(mut file: File) -> std::io::Result<(String, u64)> {
    let mut digest = Sha256::new();
    let mut bytes = 0u64;
    let mut buffer = [0u8; 8192];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
        bytes = bytes.checked_add(count as u64).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "artifact size overflow")
        })?;
    }
    Ok((hex::encode(digest.finalize()), bytes))
}

enum ReceiptRead {
    Missing,
    Invalid,
    Receipt(InstallationReceipt),
}

fn read_receipt(directory: &Path) -> ReceiptRead {
    let path = directory.join("metadata.json");
    let metadata = match std::fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return ReceiptRead::Missing,
        Err(_) => return ReceiptRead::Invalid,
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return ReceiptRead::Invalid;
    }
    match File::open(path)
        .ok()
        .and_then(|file| serde_json::from_reader(file).ok())
    {
        Some(receipt) => ReceiptRead::Receipt(receipt),
        None => ReceiptRead::Invalid,
    }
}

fn validated_receipt_artifacts(receipt: &InstallationReceipt) -> Option<BTreeMap<&str, String>> {
    if receipt
        .revision
        .as_deref()
        .is_some_and(|revision| revision.trim().is_empty())
    {
        return None;
    }
    let artifacts = receipt
        .artifacts
        .iter()
        .map(|artifact| (artifact.path.as_str(), artifact.sha256.to_ascii_lowercase()))
        .collect::<BTreeMap<_, _>>();
    if artifacts.is_empty()
        || artifacts.len() != receipt.artifacts.len()
        || artifacts.iter().any(|(path, sha256)| {
            let path = Path::new(path);
            path.as_os_str().is_empty()
                || path.is_absolute()
                || !path
                    .components()
                    .all(|component| matches!(component, std::path::Component::Normal(_)))
                || sha256.len() != 64
                || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        })
    {
        return None;
    }
    Some(artifacts)
}

fn receipt_matches_manifest(
    receipt_artifacts: &BTreeMap<&str, String>,
    manifest: &ModelManifest,
) -> bool {
    receipt_artifacts.len() == manifest.artifacts.len()
        && manifest.artifacts.iter().all(|artifact| {
            receipt_artifacts.get(artifact.name.as_str())
                == Some(&artifact.sha256.to_ascii_lowercase())
        })
}
