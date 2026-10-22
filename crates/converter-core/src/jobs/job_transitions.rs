//! Allowed lifecycle edges; persisted JobState variants remain unchanged.
use super::JobState;

pub(super) fn transition_allowed(from: JobState, to: JobState) -> bool {
    matches!(
        (from, to),
        (
            JobState::Queued,
            JobState::Running | JobState::Cancelling | JobState::Cancelled | JobState::Failed
        ) | (
            JobState::Running,
            JobState::Cancelling | JobState::Completed | JobState::Failed
        ) | (JobState::Cancelling, JobState::Cancelled | JobState::Failed)
    )
}
