//! Persistent conversion job state and lifecycle management.
//!
//! The manager owns the durable job record. Each mutation validates the typed
//! transition before replacing the JSON document, so a restart observes either
//! the old record or the complete new record, never a partial write.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

const JOB_FILE_SUFFIX: &str = ".json";
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

/// File-backed job manager with serialized mutations across its clones.
/// Resuming the same job through an independent manager still requires its
/// previous worker to have stopped, as documented by `restart`.
#[derive(Clone)]
pub struct JobManager {
    jobs_dir: Arc<PathBuf>,
    mutations: Arc<Mutex<()>>,
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
    fn independent_managers_claim_one_job_without_overwriting_the_winner() {
        let directory = tempfile::tempdir().unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(16));
        let writers: Vec<_> = (0..16)
            .map(|owner| {
                let manager = JobManager::new(directory.path()).unwrap();
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    let mut metadata = serde_json::Map::new();
                    metadata.insert("owner".into(), serde_json::json!(owner));
                    barrier.wait();
                    manager.create(JobRecord::new("shared-identity", metadata))
                })
            })
            .collect();
        let mut winner = None;
        for writer in writers {
            match writer.join().unwrap() {
                Ok(record) => {
                    assert!(
                        winner.replace(record).is_none(),
                        "only one claim may succeed"
                    );
                }
                Err(JobError::Io(error)) => assert_eq!(error.kind(), io::ErrorKind::AlreadyExists),
                other => panic!("unexpected creation result: {other:?}"),
            }
        }
        let manager = JobManager::new(directory.path()).unwrap();
        assert_eq!(manager.load("shared-identity").unwrap(), winner.unwrap());
        assert_eq!(manager.list().unwrap().len(), 1);
        // Legitimate updates still atomically replace the owning record.
        manager
            .transition("shared-identity", JobState::Running)
            .unwrap();
        assert_eq!(
            manager.load("shared-identity").unwrap().state,
            JobState::Running
        );
    }

    #[test]
    fn independent_claims_and_interrupted_staging_do_not_block_fresh_jobs() {
        let directory = tempfile::tempdir().unwrap();
        let abandoned = directory.path().join(".job-interrupted.tmp");
        fs::write(
            &abandoned,
            b"incomplete staging owned by a previous process",
        )
        .unwrap();
        let writers: Vec<_> = (0..8)
            .map(|index| {
                let manager = JobManager::new(directory.path()).unwrap();
                std::thread::spawn(move || {
                    manager.create(JobRecord::new(
                        format!("independent-{index}"),
                        Default::default(),
                    ))
                })
            })
            .collect();
        for writer in writers {
            writer.join().unwrap().unwrap();
        }
        let manager = JobManager::new(directory.path()).unwrap();
        assert_eq!(manager.list().unwrap().len(), 8);
        assert_eq!(
            fs::read(abandoned).unwrap(),
            b"incomplete staging owned by a previous process"
        );
    }

    #[test]
    fn progress_after_cancellation_preserves_state_and_terminal_records() {
        let (_directory, manager) = manager();
        let mut metadata = serde_json::Map::new();
        metadata.insert("source".into(), serde_json::json!("original-book"));
        manager
            .create(JobRecord::new("cancelled", metadata))
            .unwrap();
        manager.transition("cancelled", JobState::Running).unwrap();
        let cancelling = manager.request_cancellation("cancelled").unwrap();
        let progress = serde_json::json!({"completed": 2});
        let clone = manager.clone();
        let updated = clone
            .update_progress("cancelled", progress.clone())
            .unwrap();
        assert_eq!(updated.state, JobState::Cancelling);
        assert_eq!(updated.progress, progress);
        assert_eq!(updated.metadata, cancelling.metadata);
        assert_eq!(manager.load("cancelled").unwrap(), updated);

        let terminal = manager
            .transition("cancelled", JobState::Cancelled)
            .unwrap();
        let stored = fs::read(manager.job_path("cancelled")).unwrap();
        assert!(matches!(
            clone.update_progress("cancelled", serde_json::json!({"completed": 3})),
            Err(JobError::InvalidTransition(_))
        ));
        assert_eq!(manager.load("cancelled").unwrap(), terminal);
        assert_eq!(fs::read(manager.job_path("cancelled")).unwrap(), stored);
    }

    #[test]
    fn concurrent_progress_updates_preserve_a_valid_running_job() {
        let (_directory, manager) = manager();
        manager
            .create(JobRecord::new("shared", serde_json::Map::new()))
            .unwrap();
        manager.transition("shared", JobState::Running).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(16));
        let writers: Vec<_> = (0..16)
            .map(|writer| {
                let manager = manager.clone();
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    for step in 0..8 {
                        manager.update_progress(
                            "shared",
                            serde_json::json!({"writer":writer,"step":step}),
                        )?;
                    }
                    Ok::<_, JobError>(())
                })
            })
            .collect();
        let failures: Vec<_> = writers
            .into_iter()
            .filter_map(|writer| writer.join().expect("writer must not panic").err())
            .collect();
        assert!(
            failures.is_empty(),
            "Concurrent public progress updates failed: {failures:?}"
        );
        assert_eq!(manager.load("shared").unwrap().state, JobState::Running);
    }

    #[test]
    fn concurrent_progress_cannot_erase_durable_cancellation() {
        let (_directory, manager) = manager();
        for round in 0..4 {
            let id = format!("cancel-race-{round}");
            manager
                .create(JobRecord::new(&id, serde_json::Map::new()))
                .unwrap();
            manager.transition(&id, JobState::Running).unwrap();
            let barrier = Arc::new(std::sync::Barrier::new(9));
            let writers: Vec<_> = (0..9)
                .map(|writer| {
                    let manager = manager.clone();
                    let id = id.clone();
                    let barrier = Arc::clone(&barrier);
                    std::thread::spawn(move || -> Result<(), JobError> {
                        barrier.wait();
                        if writer == 8 {
                            manager.request_cancellation(&id)?;
                        } else {
                            for step in 0..4 {
                                manager.update_progress(
                                    &id,
                                    serde_json::json!({"writer":writer,"step":step}),
                                )?;
                            }
                        }
                        Ok(())
                    })
                })
                .collect();
            for writer in writers {
                writer.join().unwrap().unwrap();
            }
            assert_eq!(
                manager.load(&id).unwrap().state,
                JobState::Cancelling,
                "A completed cancellation request must survive concurrent progress (round {round})"
            );
        }
    }

    #[test]
    fn restart_resets_recoverable_jobs_and_preserves_completed_jobs() {
        let (_directory, manager) = manager();
        for (index, state) in [
            JobState::Queued,
            JobState::Running,
            JobState::Cancelling,
            JobState::Cancelled,
            JobState::Failed,
        ]
        .into_iter()
        .enumerate()
        {
            let id = format!("retry-{index}");
            let mut record = JobRecord::new(&id, serde_json::Map::new());
            record.state = state;
            record.progress = serde_json::json!({"completed": 2});
            manager.persist(&record).unwrap();
            let restarted = manager.restart(&id).unwrap();
            assert_eq!(restarted.state, JobState::Queued);
            assert!(restarted.progress.is_null());
            assert_eq!(restarted.created_at, record.created_at);
            assert_eq!(manager.load(&id).unwrap(), restarted);
        }
        let mut completed = JobRecord::new("done", serde_json::Map::new());
        completed.state = JobState::Completed;
        manager.persist(&completed).unwrap();
        assert!(matches!(
            manager.restart("done"),
            Err(JobError::InvalidTransition(_))
        ));
        assert_eq!(manager.load("done").unwrap(), completed);
        assert!(matches!(
            manager.restart("unknown"),
            Err(JobError::NotFound(_))
        ));
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

    #[test]
    fn cleanup_removes_expired_terminal_jobs_without_relocking() {
        let (_directory, manager) = manager();
        for (id, state) in [
            ("expired-completed", JobState::Completed),
            ("expired-cancelled", JobState::Cancelled),
            ("expired-failed", JobState::Failed),
            ("old-running", JobState::Running),
        ] {
            let mut record = JobRecord::new(id, serde_json::Map::new());
            record.state = state;
            record.updated_at = 0;
            manager.persist(&record).unwrap();
        }
        let mut recent = JobRecord::new("recent-completed", serde_json::Map::new());
        recent.state = JobState::Completed;
        manager.persist(&recent).unwrap();

        let worker = manager.clone();
        let (sender, receiver) = std::sync::mpsc::channel();
        let cleanup = std::thread::spawn(move || {
            sender.send(worker.cleanup_stale()).unwrap();
        });
        let deleted = receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("cleanup must not recursively acquire the mutation lock")
            .unwrap();
        cleanup.join().unwrap();
        assert_eq!(deleted, 3);
        for id in ["expired-completed", "expired-cancelled", "expired-failed"] {
            assert!(matches!(manager.load(id), Err(JobError::NotFound(_))));
        }
        assert_eq!(
            manager.load("old-running").unwrap().state,
            JobState::Running
        );
        assert_eq!(manager.load("recent-completed").unwrap(), recent);
        assert_eq!(manager.list().unwrap().len(), 2);
        assert_eq!(manager.cleanup_stale().unwrap(), 0);
    }
}
