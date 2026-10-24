//! Identify the extracted files actually consumed by Kokoro, never a discarded archive.
use super::WorkerError;
use std::{collections::BTreeMap, fs, path::Path};

pub(super) fn extracted_identity(
    root: &Path,
    sherpa: bool,
) -> Result<BTreeMap<String, String>, WorkerError> {
    let files = if sherpa {
        vec![
            if root.join("model.int8.onnx").is_file() {
                "model.int8.onnx"
            } else {
                "model.onnx"
            },
            "voices.bin",
            "tokens.txt",
            "espeak-ng-data/phontab",
            "espeak-ng-data/phondata",
            "espeak-ng-data/phonindex",
        ]
    } else {
        vec![
            "onnx/model_quantized.onnx",
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "voices/af.bin",
        ]
    };
    let mut identity = BTreeMap::new();
    for name in files {
        fingerprint(root, &root.join(name), &mut identity)?;
    }
    if sherpa {
        fingerprint(root, &root.join("espeak-ng-data"), &mut identity)?;
    }
    Ok(identity)
}
fn fingerprint(
    root: &Path,
    path: &Path,
    identity: &mut BTreeMap<String, String>,
) -> Result<(), WorkerError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_dir() {
        for entry in fs::read_dir(path)? {
            fingerprint(root, &entry?.path(), identity)?;
        }
    } else if metadata.is_file() && metadata.len() > 0 {
        identity.insert(
            path.strip_prefix(root)
                .expect("contained model file")
                .to_string_lossy()
                .into_owned(),
            crate::cache::sha256_file(path)?,
        );
    } else {
        return Err(WorkerError::Unsupported(
            "Kokoro artifacts must be nonempty regular files without links".into(),
        ));
    }
    Ok(())
}

/// Older official installations retain archive provenance, but no extracted-file
/// checksums. They can synthesize; their output is deliberately not reusable.
pub(super) fn validate_provenance(root: &Path, model_id: &str) -> Result<(), WorkerError> {
    let manifest = crate::model_store::ModelStore::catalog_manifest(model_id)
        .map_err(|error| WorkerError::Unsupported(error.to_string()))?;
    let metadata: serde_json::Value = crate::cache::read_json(root.join("metadata.json"))?;
    if metadata["id"] != model_id
        || manifest.artifacts.iter().any(|artifact| {
            !metadata["artifacts"].as_array().is_some_and(|entries| {
                entries.iter().any(|entry| {
                    entry["path"] == artifact.name && entry["sha256"] == artifact.sha256
                })
            })
        })
    {
        return Err(WorkerError::Unsupported(
            "Kokoro installation provenance does not match its catalog revision".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn extracted_files_have_content_identity_without_the_download_archive() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir_all(root.path().join("espeak-ng-data")).unwrap();
        for name in [
            "model.int8.onnx",
            "voices.bin",
            "tokens.txt",
            "espeak-ng-data/phontab",
            "espeak-ng-data/phondata",
            "espeak-ng-data/phonindex",
        ] {
            fs::write(root.path().join(name), name).unwrap();
        }
        let first = extracted_identity(root.path(), true).unwrap();
        assert_eq!(first.len(), 6);
        fs::write(root.path().join("voices.bin"), b"changed").unwrap();
        assert_ne!(first, extracted_identity(root.path(), true).unwrap());
        fs::remove_file(root.path().join("tokens.txt")).unwrap();
        assert!(extracted_identity(root.path(), true).is_err());
    }
    #[test]
    fn archive_metadata_cannot_claim_another_model_or_revision() {
        let root = tempfile::tempdir().unwrap();
        let model = crate::model_store::ModelStore::catalog_manifest("kokoro-82m").unwrap();
        let metadata = serde_json::json!({"id": "kokoro-82m", "artifacts": model.artifacts.iter().map(|artifact| serde_json::json!({"path":artifact.name,"sha256":artifact.sha256})).collect::<Vec<_>>()});
        crate::cache::atomic_write_json(root.path().join("metadata.json"), &metadata).unwrap();
        validate_provenance(root.path(), "kokoro-82m").unwrap();
        let mut wrong = metadata;
        wrong["artifacts"][0]["sha256"] = "changed".into();
        crate::cache::atomic_write_json(root.path().join("metadata.json"), &wrong).unwrap();
        assert!(validate_provenance(root.path(), "kokoro-82m").is_err());
    }
}
