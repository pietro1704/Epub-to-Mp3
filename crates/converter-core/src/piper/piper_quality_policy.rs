//! Product quality policy shared by catalog selection and native preparation.
use super::{validate_model_quality, PiperError};
use std::path::Path;

pub(crate) fn validate_model_file_quality(model: &Path, config: &Path) -> Result<(), PiperError> {
    if !model.is_file() {
        return Err(PiperError::MissingModel(model.to_owned()));
    }
    if !config.is_file() {
        return Err(PiperError::MissingConfig(config.to_owned()));
    }
    for path in [model, config] {
        // Directory names do not declare voice quality. Check filenames and
        // their symlink targets; explicit namespace IDs are checked separately.
        for candidate in [Some(path.to_path_buf()), path.canonicalize().ok()]
            .into_iter()
            .flatten()
        {
            if let Some(filename) = candidate.file_name() {
                validate_model_quality(&filename.to_string_lossy())
                    .map_err(PiperError::Synthesis)?;
            }
        }
    }
    let bytes = std::fs::read(config).map_err(|error| PiperError::Io(error.to_string()))?;
    let metadata: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|error| PiperError::Synthesis(format!("Invalid Piper model config: {error}")))?;
    if let Some(quality) = metadata
        .pointer("/audio/quality")
        .and_then(|value| value.as_str())
    {
        validate_model_quality(quality).map_err(PiperError::Synthesis)?;
    }
    Ok(())
}
