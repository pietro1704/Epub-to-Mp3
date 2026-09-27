//! Persistent conversion job state and lifecycle management.
//!
//! The manager owns the durable job record. Each mutation validates the typed
//! transition before replacing the JSON document, so a restart observes either
//! the old record or the complete new record, never a partial write.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

const JOB_FILE_SUFFIX: &str = ".json";
const TEMP_FILE_SUFFIX: &str = ".tmp";
const DEFAULT_TTL: Duration = Duration::from_secs(48 * 60 * 60);

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

    fn transition(&mut self, state: JobState) -> Result<(), InvalidTransition> {
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

/// A recovered active job that needs its worker resumed by the caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoveryItem {
    pub job_id: String,
    pub state: JobState,
}

/// Errors from persistent job operations.
#[derive(Debug)]
pub enum JobError {
    Io(io::Error),
    Json(serde_json::Error),
    InvalidTransition(InvalidTransition),
    InvalidJobId,
    NotFound(String),
}

impl std::fmt::Display for JobError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(f, "job storage error: {error}"),
            Self::Json(error) => write!(f, "invalid job JSON: {error}"),
            Self::InvalidTransition(error) => error.fmt(f),
            Self::InvalidJobId => write!(f, "invalid job ID"),
            Self::NotFound(job_id) => write!(f, "job not found: {job_id}"),
        }
    }
}

impl std::error::Error for JobError {}
impl From<io::Error> for JobError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<serde_json::Error> for JobError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}
impl From<InvalidTransition> for JobError {
    fn from(error: InvalidTransition) -> Self {
        Self::InvalidTransition(error)
    }
}

/// Thread-safe, file-backed job manager.
#[derive(Clone)]
pub struct JobManager {
    jobs_dir: Arc<PathBuf>,
    ttl: Duration,
}

impl JobManager {
    pub fn new(jobs_dir: impl Into<PathBuf>) -> Result<Self, JobError> {
        Self::with_ttl(jobs_dir, DEFAULT_TTL)
    }

    pub fn with_ttl(jobs_dir: impl Into<PathBuf>, ttl: Duration) -> Result<Self, JobError> {
        let jobs_dir = jobs_dir.into();
        fs::create_dir_all(&jobs_dir)?;
        Ok(Self {
            jobs_dir: Arc::new(jobs_dir),
            ttl,
        })
    }

    pub fn jobs_dir(&self) -> &Path {
        self.jobs_dir.as_path()
    }

    pub fn create(&self, record: JobRecord) -> Result<JobRecord, JobError> {
        validate_job_id(&record.job_id)?;
        let path = self.job_path(&record.job_id);
        if path.exists() {
            return Err(JobError::Io(io::Error::new(
                io::ErrorKind::AlreadyExists,
                record.job_id,
            )));
        }
        self.persist(&record)?;
        Ok(record)
    }

    pub fn load(&self, job_id: &str) -> Result<JobRecord, JobError> {
        validate_job_id(job_id)?;
        let bytes = fs::read(self.job_path(job_id)).map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                JobError::NotFound(job_id.into())
            } else {
                JobError::Io(error)
            }
        })?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    pub fn list(&self) -> Result<Vec<JobRecord>, JobError> {
        let mut records = Vec::new();
        for entry in fs::read_dir(self.jobs_dir())? {
            let path = entry?.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            match fs::read(&path).and_then(|bytes| {
                serde_json::from_slice::<JobRecord>(&bytes).map_err(io::Error::other)
            }) {
                Ok(record) => records.push(record),
                Err(error) => return Err(JobError::Io(error)),
            }
        }
        records.sort_by(|left, right| {
            left.created_at
                .cmp(&right.created_at)
                .then(left.job_id.cmp(&right.job_id))
        });
        Ok(records)
    }

    pub fn transition(&self, job_id: &str, state: JobState) -> Result<JobRecord, JobError> {
        let mut record = self.load(job_id)?;
        record.transition(state)?;
        self.persist(&record)?;
        Ok(record)
    }

    pub fn update_progress(
        &self,
        job_id: &str,
        progress: serde_json::Value,
    ) -> Result<JobRecord, JobError> {
        let mut record = self.load(job_id)?;
        if !record.state.is_active() {
            return Err(JobError::InvalidTransition(InvalidTransition {
                from: record.state,
                to: record.state,
            }));
        }
        record.progress = progress;
        record.updated_at = unix_now();
        self.persist(&record)?;
        Ok(record)
    }

    /// Mark a job for cancellation. Workers should call `is_cancellation_requested`
    /// and then finish with the `Cancelled` transition.
    pub fn request_cancellation(&self, job_id: &str) -> Result<JobRecord, JobError> {
        self.transition(job_id, JobState::Cancelling)
    }

    pub fn is_cancellation_requested(&self, job_id: &str) -> Result<bool, JobError> {
        Ok(matches!(self.load(job_id)?.state, JobState::Cancelling))
    }

    pub fn delete(&self, job_id: &str) -> Result<(), JobError> {
        validate_job_id(job_id)?;
        match fs::remove_file(self.job_path(job_id)) {
            Ok(()) => Ok(()),
            Err(error) if !self.job_path(job_id).exists() => Ok(()),
            Err(error) => Err(JobError::Io(error)),
        }
    }

    /// Recover active jobs after a process restart without changing their
    /// state. The worker layer owns resumption and can safely inspect records.
    pub fn recover_active(&self) -> Result<Vec<RecoveryItem>, JobError> {
        Ok(self
            .list()?
            .into_iter()
            .filter(|record| record.state.is_active())
            .map(|record| RecoveryItem {
                job_id: record.job_id,
                state: record.state,
            })
            .collect())
    }

    /// Remove expired terminal jobs. Active jobs are never deleted by TTL.
    pub fn cleanup_stale(&self) -> Result<usize, JobError> {
        let cutoff = unix_now().saturating_sub(self.ttl.as_secs());
        let mut deleted = 0;
        for record in self.list()? {
            if !record.state.is_active() && record.updated_at < cutoff {
                self.delete(&record.job_id)?;
                deleted += 1;
            }
        }
        Ok(deleted)
    }

    fn job_path(&self, job_id: &str) -> PathBuf {
        self.jobs_dir.join(format!("{job_id}{JOB_FILE_SUFFIX}"))
    }

    fn persist(&self, record: &JobRecord) -> Result<(), JobError> {
        validate_job_id(&record.job_id)?;
        let target = self.job_path(&record.job_id);
        let temp = self.jobs_dir.join(format!(
            ".{0}.{1}{TEMP_FILE_SUFFIX}",
            record.job_id,
            std::process::id()
        ));
        let bytes = serde_json::to_vec_pretty(record)?;
        let result = (|| -> Result<(), JobError> {
            let mut file = OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(&temp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temp, &target)?;
            sync_directory(self.jobs_dir())?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        result
    }
}

fn transition_allowed(from: JobState, to: JobState) -> bool {
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

fn validate_job_id(job_id: &str) -> Result<(), JobError> {
    if job_id.is_empty()
        || job_id == "."
        || job_id == ".."
        || job_id.contains('/')
        || job_id.contains('\\')
        || job_id.contains('\0')
    {
        Err(JobError::InvalidJobId)
    } else {
        Ok(())
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn sync_directory(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        File::open(path)?.sync_all()
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn manager() -> (tempfile::TempDir, JobManager) {
        let directory = tempfile::tempdir().unwrap();
        let manager = JobManager::with_ttl(directory.path(), Duration::from_secs(60)).unwrap();
        (directory, manager)
    }

    #[test]
    fn persists_typed_transitions_and_recovers_active_jobs() {
        let (_directory, manager) = manager();
        manager
            .create(JobRecord::new("job-1", serde_json::Map::new()))
            .unwrap();
        manager.transition("job-1", JobState::Running).unwrap();
        let restarted = JobManager::new(manager.jobs_dir()).unwrap();
        assert_eq!(
            restarted.recover_active().unwrap(),
            vec![RecoveryItem {
                job_id: "job-1".into(),
                state: JobState::Running
            }]
        );
        assert!(restarted.transition("job-1", JobState::Completed).is_ok());
        assert!(matches!(
            restarted.transition("job-1", JobState::Running),
            Err(JobError::InvalidTransition(_))
        ));
    }

    #[test]
    fn cancellation_is_durable_and_active_jobs_are_ttl_protected() {
        let (_directory, manager) = manager();
        manager
            .create(JobRecord::new("job-2", serde_json::Map::new()))
            .unwrap();
        manager.request_cancellation("job-2").unwrap();
        assert!(manager.is_cancellation_requested("job-2").unwrap());
        assert_eq!(manager.cleanup_stale().unwrap(), 0);
    }
}
