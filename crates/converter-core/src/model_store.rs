//! Verified, atomic storage for downloadable TTS models.
#[cfg(feature = "kokoro-sherpa-runtime")]
mod model_archive_installation;
mod model_inspection;
mod model_install_operation;
mod model_installation;
pub(crate) mod model_usage;
pub use model_inspection::{InstalledModelInspection, InstalledModelState};
pub use model_install_operation::{
    ModelInstallArtifactPlan, ModelInstallEvent, ModelInstallFailure, ModelInstallOperation,
    ModelInstallPlan, ModelInstallStage,
};
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
    pub revision: Option<String>,
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
    #[error("invalid model id: {0}")]
    InvalidModelId(String),
    #[error("model manifest is empty")]
    EmptyManifest,
    #[error("unknown TTS model: {0}")]
    UnknownModel(String),
    #[error("model is currently in use: {0}")]
    ModelInUse(String),
    #[error("invalid model archive: {0}")]
    InvalidArchive(String),
    #[error("model installation requires {required_bytes} bytes but only {available_bytes} are available")]
    InsufficientSpace {
        required_bytes: u64,
        available_bytes: u64,
    },
    #[error("model installation was cancelled")]
    Cancelled,
    #[error("model installation operation has already finished")]
    OperationFinished,
    #[error(
        "model installation progress regressed from {previous_bytes} to {reported_bytes} bytes"
    )]
    ProgressRegressed {
        previous_bytes: u64,
        reported_bytes: u64,
    },
    #[error("model installation artifact {0} is outside the owned download inbox")]
    InvalidDownloadedArtifact(usize),
    #[error("model installation is waiting for artifact {0}")]
    ArtifactPending(usize),
    #[error("no pending model installation exists")]
    NoPendingInstall,
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
