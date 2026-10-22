//! Persistent conversion job state and lifecycle management.
//!
//! The manager owns the durable job record. Each mutation validates the typed
//! transition before replacing the JSON document, so a restart observes either
//! the old record or the complete new record, never a partial write.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

const JOB_FILE_SUFFIX: &str = ".json";
const DEFAULT_TTL: Duration = Duration::from_secs(48 * 60 * 60);

mod job_record;
mod job_transitions;
use job_record::unix_now;
pub use job_record::{InvalidTransition, JobRecord, JobState};

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

/// File-backed job manager with serialized mutations across its clones.
/// Resuming the same job through an independent manager still requires its
/// previous worker to have stopped, as documented by `restart`.
#[derive(Clone)]
pub struct ConversionJobStore {
    jobs_dir: Arc<PathBuf>,
    mutations: Arc<Mutex<()>>,
    ttl: Duration,
}

impl ConversionJobStore {
    pub fn new(jobs_dir: impl Into<PathBuf>) -> Result<Self, JobError> {
        Self::with_ttl(jobs_dir, DEFAULT_TTL)
    }

    pub fn with_ttl(jobs_dir: impl Into<PathBuf>, ttl: Duration) -> Result<Self, JobError> {
        let jobs_dir = jobs_dir.into();
        fs::create_dir_all(&jobs_dir)?;
        Ok(Self {
            jobs_dir: Arc::new(jobs_dir),
            mutations: Arc::new(Mutex::new(())),
            ttl,
        })
    }

    pub fn jobs_dir(&self) -> &Path {
        self.jobs_dir.as_path()
    }

    pub fn create(&self, record: JobRecord) -> Result<JobRecord, JobError> {
        let _mutation = self.mutation_guard()?;
        validate_job_id(&record.job_id)?;
        // Independent workers do not share this manager's mutex. Publish the
        // complete initial record without replacing another worker's claim.
        self.persist_record(&record, true)?;
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
        let _mutation = self.mutation_guard()?;
        let mut record = self.load(job_id)?;
        record.transition(state)?;
        self.persist(&record)?;
        Ok(record)
    }

    /// Reset a recoverable job for another attempt. The caller must ensure no
    /// worker is still running for this job, including after process recovery.
    pub fn restart(&self, job_id: &str) -> Result<JobRecord, JobError> {
        let _mutation = self.mutation_guard()?;
        let mut record = self.load(job_id)?;
        if record.state == JobState::Completed {
            return Err(JobError::InvalidTransition(InvalidTransition {
                from: record.state,
                to: JobState::Queued,
            }));
        }
        record.state = JobState::Queued;
        record.progress = serde_json::Value::Null;
        record.updated_at = unix_now();
        self.persist(&record)?;
        Ok(record)
    }

    pub fn update_progress(
        &self,
        job_id: &str,
        progress: serde_json::Value,
    ) -> Result<JobRecord, JobError> {
        let _mutation = self.mutation_guard()?;
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
        let _mutation = self.mutation_guard()?;
        self.delete_record(job_id)
    }

    fn delete_record(&self, job_id: &str) -> Result<(), JobError> {
        validate_job_id(job_id)?;
        match fs::remove_file(self.job_path(job_id)) {
            Ok(()) => Ok(()),
            Err(_error) if !self.job_path(job_id).exists() => Ok(()),
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
        let _mutation = self.mutation_guard()?;
        let cutoff = unix_now().saturating_sub(self.ttl.as_secs());
        let mut deleted = 0;
        for record in self.list()? {
            if !record.state.is_active() && record.updated_at < cutoff {
                self.delete_record(&record.job_id)?;
                deleted += 1;
            }
        }
        Ok(deleted)
    }

    fn job_path(&self, job_id: &str) -> PathBuf {
        self.jobs_dir.join(format!("{job_id}{JOB_FILE_SUFFIX}"))
    }

    fn mutation_guard(&self) -> Result<MutexGuard<'_, ()>, JobError> {
        self.mutations
            .lock()
            .map_err(|_| JobError::Io(io::Error::other("job mutation lock poisoned")))
    }

    fn persist(&self, record: &JobRecord) -> Result<(), JobError> {
        self.persist_record(record, false)
    }

    fn persist_record(&self, record: &JobRecord, create: bool) -> Result<(), JobError> {
        validate_job_id(&record.job_id)?;
        let target = self.job_path(&record.job_id);
        let bytes = serde_json::to_vec_pretty(record)?;
        let mut staging = tempfile::Builder::new()
            .prefix(".job-")
            .tempfile_in(self.jobs_dir())?;
        staging.write_all(&bytes)?;
        staging.as_file().sync_all()?;
        if create {
            staging
                .persist_noclobber(&target)
                .map_err(|error| error.error)?;
        } else {
            staging.persist(&target).map_err(|error| error.error)?;
        }
        sync_directory(self.jobs_dir())?;
        Ok(())
    }
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
#[path = "jobs/job_store_tests.rs"]
mod tests;
