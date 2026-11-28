//! Earlier jobs of the same book that stopped before finishing. Their completed
//! chapters are candidates for reuse; each chapter's completion receipt still
//! decides whether its text, voice and options match the new request.
use super::{ConversionWorker, WorkerError};
use crate::{cache, jobs::JobState};
use std::path::PathBuf;

impl ConversionWorker {
    fn job_source_path(&self, job_id: &str) -> PathBuf {
        self.config
            .paths
            .jobs_dir
            .join("sources")
            .join(format!("{job_id}.json"))
    }

    /// Which book a job read, by content, kept even when the job never finishes.
    pub(super) fn record_job_source(
        &self,
        job_id: &str,
        book_key: &str,
    ) -> Result<(), WorkerError> {
        cache::atomic_write_json(self.job_source_path(job_id), &book_key)?;
        Ok(())
    }

    /// Job IDs to recover chapters from, most recent first. A recovery job named
    /// by the caller is authoritative; asking for fresh audio disables recovery,
    /// and so does a repair, which must not restore audio it just withdrew.
    pub(super) fn recovery_candidates(&self, job_id: &str, book_key: &str) -> Vec<String> {
        if let Some(named) = self
            .control
            .as_ref()
            .and_then(|control| control.recover_job())
        {
            return vec![named];
        }
        if self.execution_options.clear_cache
            || self.execution_options.force_reprocess
            || self.repairing.load(std::sync::atomic::Ordering::Acquire)
        {
            return Vec::new();
        }
        // Reuse is an optimization: an unreadable job store only means synthesis.
        let mut records = self.jobs.list().unwrap_or_default();
        records.sort_by_key(|record| std::cmp::Reverse(record.updated_at));
        records
            .into_iter()
            .filter(|record| record.state != JobState::Completed && record.job_id != job_id)
            .filter(|record| {
                cache::read_json::<String>(self.job_source_path(&record.job_id))
                    .is_ok_and(|source| source == book_key)
            })
            .map(|record| record.job_id)
            .collect()
    }
}
