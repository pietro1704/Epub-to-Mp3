//! Validate archive paths and unpack verified model artifacts into staging.
use super::ModelStoreError;
use bzip2::read::BzDecoder;
use std::path::Path;
use tar::Archive;

pub(super) fn extract_model_archive(
    archive_path: &Path,
    staging: &Path,
) -> Result<(), ModelStoreError> {
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
