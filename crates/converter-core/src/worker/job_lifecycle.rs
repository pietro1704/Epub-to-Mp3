//! Exclusive ownership of a job across conversion, retry and in-place repair.
use super::*;
use std::fs::{self, File, OpenOptions, TryLockError};

/// Lock files stay in place: unlinking one while another worker opens it could
/// create two lockable inodes for the same job. The OS releases the lease on exit.
fn claim_job(jobs_dir: &std::path::Path, job_id: &str) -> Result<File, WorkerError> {
    if job_id.is_empty() || matches!(job_id, "." | "..") || job_id.contains(['/', '\\', '\0']) {
        return Err(JobError::InvalidJobId.into());
    }
    let directory = jobs_dir.join(".worker-locks");
    fs::create_dir_all(&directory)?;
    let lease = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(directory.join(format!("{job_id}.lock")))?;
    match lease.try_lock() {
        Ok(()) => Ok(lease),
        Err(TryLockError::WouldBlock) => Err(WorkerError::Unsupported(format!(
            "job {job_id} is owned by another worker"
        ))),
        Err(TryLockError::Error(error)) => Err(error.into()),
    }
}

fn reject_symlink(path: &std::path::Path) -> Result<(), WorkerError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(WorkerError::Unsupported(
            format!("repair refuses symlink {}", path.display()),
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

impl ConversionWorker {
    pub(crate) fn with_expected_source_sha256(mut self, expected: Option<String>) -> Self {
        self.expected_source_sha256 = Mutex::new(expected);
        self
    }

    pub(super) fn validate_source_identity(&self, actual: &str) -> Result<(), WorkerError> {
        let expected = self
            .expected_source_sha256
            .lock()
            .map_err(|_| io::Error::other("source identity lock poisoned"))?;
        if expected
            .as_deref()
            .is_some_and(|expected| expected != actual)
        {
            return Err(WorkerError::Unsupported(
                "source changed since the original conversion".into(),
            ));
        }
        Ok(())
    }

    fn validate_request_source(&self, request: &ConversionRequest) -> Result<(), WorkerError> {
        if self
            .expected_source_sha256
            .lock()
            .map_err(|_| io::Error::other("source identity lock poisoned"))?
            .is_some()
        {
            self.validate_source_identity(&cache::sha256_file(&request.input)?)?;
        }
        Ok(())
    }

    pub fn run(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        let _lease = claim_job(&self.config.paths.jobs_dir, &request.job_id)?;
        self.validate_request_source(&request)?;
        let request = self.capture_request_preferences(request)?;
        self.run_claimed(request)
    }

    fn run_claimed(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        let primary = request
            .tts_preferences
            .as_ref()
            .map(|preferences| &preferences.primary);
        let metadata = serde_json::json!({
            "input": request.input,
            "engine": primary.map(|selection| &selection.engine).or(request.engine.as_ref()),
            "voice": primary.map_or(request.voice.as_ref(), |selection| selection.voice.as_ref()),
            "language": request.language,
            "tts_preferences": request.tts_preferences,
            "models_root": request.models_root,
            "piper_model": request.piper_model,
            "piper_config": request.piper_config
        });

        self.jobs.create(JobRecord::new(
            &request.job_id,
            metadata.as_object().cloned().unwrap_or_default(),
        ))?;
        self.run_prepared(request)
    }

    /// Retry a job whose previous worker has stopped, preserving its output ID
    /// and chapter paths across attempts.
    pub fn resume(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        let _lease = claim_job(&self.config.paths.jobs_dir, &request.job_id)?;
        self.validate_request_source(&request)?;
        let request = self.capture_request_preferences(request)?;
        match self.jobs.restart(&request.job_id) {
            Ok(_) => self.run_prepared(request),
            Err(JobError::NotFound(_)) => self.run_claimed(request),
            Err(error) => Err(error.into()),
        }
    }

    fn run_prepared(&self, request: ConversionRequest) -> Result<OutputManifest, WorkerError> {
        self.jobs.transition(&request.job_id, JobState::Running)?;
        let result = self.run_inner(&request);
        self.tts_sessions
            .lock()
            .expect("TTS session lock")
            .retain(|(job, _, _), _| job != &request.job_id);
        match &result {
            Ok(_) => {
                self.jobs.transition(&request.job_id, JobState::Completed)?;
            }
            Err(WorkerError::Cancelled) => {
                // A control token can cancel without a persisted request. Follow
                // the state machine before reporting terminal cancellation.
                if self.jobs.load(&request.job_id)?.state != JobState::Cancelling {
                    self.jobs.request_cancellation(&request.job_id)?;
                }
                self.jobs.transition(&request.job_id, JobState::Cancelled)?;
            }
            Err(_) => {
                let _ = self.jobs.transition(&request.job_id, JobState::Failed);
            }
        }
        result
    }

    /// Repair source chapters only after acquiring the same exclusive lease
    /// held by ordinary conversion and retry. A recorded active job is refused
    /// before its completion receipts or durable record are touched.
    pub fn repair_chapters(
        &self,
        request: ConversionRequest,
        source_indices: &[usize],
    ) -> Result<OutputManifest, WorkerError> {
        let _lease = claim_job(&self.config.paths.jobs_dir, &request.job_id)?;
        match self.jobs.load(&request.job_id) {
            Ok(record) if record.state.is_active() => {
                return Err(WorkerError::Unsupported(format!(
                    "job {} is recorded as still active",
                    request.job_id
                )))
            }
            Ok(_) | Err(JobError::NotFound(_)) => {}
            Err(error) => return Err(error.into()),
        }
        let output = self.config.paths.output_dir.join(&request.job_id);
        reject_symlink(&output)?;
        reject_symlink(&output.join("manifest.json"))?;
        let manifest = match cache::read_json::<OutputManifest>(output.join("manifest.json")) {
            Ok(manifest) => Some(manifest),
            Err(cache::CacheError::Io(error))
                if error.kind() == io::ErrorKind::NotFound && source_indices.is_empty() =>
            {
                None
            }
            Err(error) => return Err(error.into()),
        };
        let mut receipts = Vec::new();
        if let Some(manifest) = manifest {
            if manifest.job_id != request.job_id {
                return Err(JobError::InvalidJobId.into());
            }
            if let Some(expected) = manifest.source_sha256 {
                self.validate_source_identity(&expected)?;
                *self
                    .expected_source_sha256
                    .lock()
                    .map_err(|_| io::Error::other("source identity lock poisoned"))? =
                    Some(expected);
            }
            for chapter in &manifest.chapters {
                let name = std::path::Path::new(&chapter.filename);
                if name.components().count() != 1
                    || name.file_name().and_then(|name| name.to_str())
                        != Some(chapter.filename.as_str())
                {
                    return Err(WorkerError::Unsupported(
                        "unsafe chapter filename in repair manifest".into(),
                    ));
                }
                let audio = output.join(name);
                reject_symlink(&audio)?;
                reject_symlink(&chapter_audio_receipt_path(&audio))?;
                if source_indices.contains(&chapter.source_index) {
                    receipts.push(audio);
                }
            }
            for index in source_indices {
                if !manifest
                    .chapters
                    .iter()
                    .any(|chapter| chapter.source_index == *index)
                {
                    return Err(WorkerError::Unsupported(format!(
                        "source chapter {index} is absent from job {}",
                        request.job_id
                    )));
                }
            }
        }
        self.validate_request_source(&request)?;
        let request = self.capture_request_preferences(request)?;
        // All rejection checks precede the first receipt mutation.
        for audio in receipts {
            discard_chapter_audio_receipt(&audio)?;
        }
        self.repairing
            .store(true, std::sync::atomic::Ordering::Release);
        let result = match self.jobs.restart_for_repair(&request.job_id) {
            Ok(_) => self.run_prepared(request),
            Err(JobError::NotFound(_)) => self.run_claimed(request),
            Err(error) => Err(error.into()),
        };
        self.repairing
            .store(false, std::sync::atomic::Ordering::Release);
        result
    }
}
