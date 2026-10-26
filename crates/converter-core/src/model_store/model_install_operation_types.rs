use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelInstallStage {
    Preflight,
    Downloading,
    Verifying,
    Publishing,
    Completed,
    Cancelled,
    Failed,
}

impl ModelInstallStage {
    pub(super) fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Cancelled | Self::Failed)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelInstallFailure {
    pub kind: String,
    pub message: String,
    pub required_bytes: Option<u64>,
    pub available_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelInstallEvent {
    pub sequence: u64,
    pub operation_id: String,
    pub model_id: String,
    pub stage: ModelInstallStage,
    pub artifact_index: Option<usize>,
    pub bytes_completed: u64,
    pub bytes_total: u64,
    pub failure: Option<ModelInstallFailure>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelInstallArtifactPlan {
    pub index: usize,
    pub name: String,
    pub url: String,
    pub sha256: String,
    pub expected_bytes: u64,
    pub inbox_path: PathBuf,
    pub accepted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelInstallPlan {
    pub version: u32,
    pub operation_id: String,
    pub model_id: String,
    pub revision: Option<String>,
    pub required_bytes: u64,
    pub available_bytes: u64,
    pub ready: bool,
    pub artifacts: Vec<ModelInstallArtifactPlan>,
    pub event: ModelInstallEvent,
}
