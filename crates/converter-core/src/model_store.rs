//! Verified, atomic storage for downloadable TTS models.
#[cfg(feature = "kokoro-sherpa-runtime")]
mod model_archive_installation;
mod model_installation;
pub use model_installation::ModelStore;

#[cfg(test)]
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use thiserror::Error;

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
    #[error("model download URL must use HTTPS")]
    InsecureUrl,
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
    #[error("invalid model archive: {0}")]
    InvalidArchive(String),
}

#[derive(Debug, Clone)]
pub struct InstalledModel {
    pub id: String,
    pub path: PathBuf,
    pub sha256: String,
}

#[cfg(test)]
#[path = "model_store/model_store_contract_tests.rs"]
mod tests;
