//! Durable job schema and timestamped state mutation.
use super::job_transitions::transition_allowed;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

/// Durable lifecycle states for a conversion job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum JobState {
    Queued,
    Running,
    Cancelling,
    Cancelled,
    Completed,
    Failed,
}

impl JobState {
    pub fn is_active(self) -> bool {
        matches!(self, Self::Queued | Self::Running | Self::Cancelling)
    }
}

/// Error returned when a requested lifecycle transition is invalid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidTransition {
    pub from: JobState,
    pub to: JobState,
}

impl std::fmt::Display for InvalidTransition {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "invalid job transition: {:?} -> {:?}",
            self.from, self.to
        )
    }
}

impl std::error::Error for InvalidTransition {}

/// A JSON-compatible job record. Extra conversion metadata is intentionally
/// represented as a JSON object so the manager remains format-agnostic.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JobRecord {
    pub job_id: String,
    pub state: JobState,
    pub created_at: u64,
    pub updated_at: u64,
    #[serde(default)]
    pub progress: serde_json::Value,
    #[serde(default)]
    pub metadata: serde_json::Map<String, serde_json::Value>,
}

impl JobRecord {
    pub fn new(
        job_id: impl Into<String>,
        metadata: serde_json::Map<String, serde_json::Value>,
    ) -> Self {
        let now = unix_now();
        Self {
            job_id: job_id.into(),
            state: JobState::Queued,
            created_at: now,
            updated_at: now,
            progress: serde_json::json!({}),
            metadata,
        }
    }

    pub(super) fn transition(&mut self, state: JobState) -> Result<(), InvalidTransition> {
        if !transition_allowed(self.state, state) {
            return Err(InvalidTransition {
                from: self.state,
                to: state,
            });
        }
        self.state = state;
        self.updated_at = unix_now();
        Ok(())
    }
}

pub(super) fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
