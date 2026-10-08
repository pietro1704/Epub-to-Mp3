//! Per-invocation cancellation and dynamic source-chapter scheduling.

use crate::piper::CancellationToken;
use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ConversionControlError {
    #[error("source chapter {0} is not selected or has already started")]
    UnavailableChapter(usize),
    #[error("conversion control queue is already attached")]
    AlreadyAttached,
    #[error("conversion control lock poisoned")]
    LockPoisoned,
    #[error("invalid recovery job ID")]
    InvalidRecoveryJob,
}

#[derive(Default)]
struct QueueState {
    attached: bool,
    pending_priority: Option<usize>,
    remaining: VecDeque<usize>,
    paused: bool,
    recovery_job: Option<String>,
}

/// Shared only by one conversion invocation and its native control handle.
#[derive(Clone, Default)]
pub struct ConversionControl {
    cancel: CancellationToken,
    queue: Arc<Mutex<QueueState>>,
    ready: Arc<Condvar>,
}

impl ConversionControl {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    pub fn cancel(&self) {
        // Synchronize the flag with wait registration to avoid a lost wakeup.
        let _queue = self.queue.lock().unwrap_or_else(|error| error.into_inner());
        self.cancel.cancel();
        self.ready.notify_all();
    }

    /// Adapter-supplied resource/network gating; no policy thresholds live here.
    pub fn set_paused(&self, paused: bool) {
        let mut queue = self.queue.lock().unwrap_or_else(|error| error.into_inner());
        queue.paused = paused;
        if !paused {
            self.ready.notify_all();
        }
    }

    pub fn set_recovery_job(&self, source_job_id: &str) -> Result<(), ConversionControlError> {
        if source_job_id.is_empty()
            || matches!(source_job_id, "." | "..")
            || source_job_id.contains(['/', '\\', '\0'])
        {
            return Err(ConversionControlError::InvalidRecoveryJob);
        }
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| ConversionControlError::LockPoisoned)?;
        if queue.attached {
            return Err(ConversionControlError::AlreadyAttached);
        }
        queue.recovery_job = Some(source_job_id.to_owned());
        Ok(())
    }

    pub fn recover_job(&self) -> Option<String> {
        self.queue
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .recovery_job
            .clone()
    }

    /// Keep intent before discovery; once attached, only unstarted selected
    /// source identities can become the next synthesis boundary.
    pub fn prioritize(&self, source_index: usize) -> Result<(), ConversionControlError> {
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| ConversionControlError::LockPoisoned)?;
        if !queue.attached {
            queue.pending_priority = Some(source_index);
            return Ok(());
        }
        if !queue.remaining.contains(&source_index) {
            return Err(ConversionControlError::UnavailableChapter(source_index));
        }
        rotate_to(&mut queue.remaining, source_index);
        Ok(())
    }

    pub(crate) fn attach(&self, selected: &[usize]) -> Result<(), ConversionControlError> {
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| ConversionControlError::LockPoisoned)?;
        if queue.attached {
            return Err(ConversionControlError::AlreadyAttached);
        }
        if let Some(priority) = queue.pending_priority {
            if !selected.contains(&priority) {
                return Err(ConversionControlError::UnavailableChapter(priority));
            }
        }
        queue.remaining = selected.iter().copied().collect();
        if let Some(priority) = queue.pending_priority.take() {
            rotate_to(&mut queue.remaining, priority);
        }
        queue.attached = true;
        Ok(())
    }

    pub(crate) fn take(&self) -> Result<Option<usize>, ConversionControlError> {
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| ConversionControlError::LockPoisoned)?;
        while queue.paused && !queue.remaining.is_empty() && !self.cancel.is_cancelled() {
            queue = self
                .ready
                .wait(queue)
                .map_err(|_| ConversionControlError::LockPoisoned)?;
        }
        if self.cancel.is_cancelled() {
            return Ok(None);
        }
        Ok(queue.remaining.pop_front())
    }
}

fn rotate_to(queue: &mut VecDeque<usize>, source_index: usize) {
    queue.make_contiguous().sort_unstable();
    if let Some(position) = queue.iter().position(|index| *index == source_index) {
        queue.rotate_left(position);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_priority_rotates_selected_source_order_and_wraps() {
        let control = ConversionControl::new();
        control.prioritize(4).unwrap();
        control.attach(&[0, 2, 4, 6]).unwrap();
        assert_eq!(control.take().unwrap(), Some(4));
        assert_eq!(control.take().unwrap(), Some(6));
        assert_eq!(control.take().unwrap(), Some(0));
        assert_eq!(control.take().unwrap(), Some(2));
        assert_eq!(control.take().unwrap(), None);
    }

    #[test]
    fn priority_changes_only_unstarted_selected_chapters() {
        let control = ConversionControl::new();
        control.attach(&[0, 1, 2, 3]).unwrap();
        assert_eq!(control.take().unwrap(), Some(0));
        control.prioritize(3).unwrap();
        assert_eq!(control.take().unwrap(), Some(3));
        assert_eq!(
            control.prioritize(0),
            Err(ConversionControlError::UnavailableChapter(0))
        );
        assert_eq!(
            control.prioritize(8),
            Err(ConversionControlError::UnavailableChapter(8))
        );
        assert_eq!(control.take().unwrap(), Some(1));
        assert_eq!(control.take().unwrap(), Some(2));
    }

    #[test]
    fn invalid_pending_target_is_rejected_when_selection_attaches() {
        let control = ConversionControl::new();
        control.prioritize(9).unwrap();
        assert_eq!(
            control.attach(&[0, 1]),
            Err(ConversionControlError::UnavailableChapter(9))
        );
    }

    #[test]
    fn clones_share_cancellation_and_queue_but_other_invocations_do_not() {
        let control = ConversionControl::new();
        let cloned = control.clone();
        cloned.cancel();
        assert!(control.cancellation_token().is_cancelled());
        assert!(!ConversionControl::new().cancellation_token().is_cancelled());
    }

    #[test]
    fn recovery_job_is_owned_safe_and_immutable_after_attach() {
        let control = ConversionControl::new();
        {
            let source = String::from("previous-job");
            control.set_recovery_job(&source).unwrap();
        }
        assert_eq!(control.recover_job().as_deref(), Some("previous-job"));
        assert_eq!(
            control.set_recovery_job("../outside"),
            Err(ConversionControlError::InvalidRecoveryJob)
        );
        control.attach(&[0]).unwrap();
        assert_eq!(
            control.set_recovery_job("other"),
            Err(ConversionControlError::AlreadyAttached)
        );
    }

    #[test]
    fn pausing_after_last_chapter_does_not_block_empty_queue() {
        let control = ConversionControl::new();
        control.attach(&[0]).unwrap();
        assert_eq!(control.take().unwrap(), Some(0));
        control.set_paused(true);
        let cloned = control.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let waiting = std::thread::spawn(move || tx.send(cloned.take()).unwrap());
        let result = rx.recv_timeout(std::time::Duration::from_secs(1));
        control.set_paused(false);
        waiting.join().unwrap();
        assert_eq!(
            result.expect("empty queue must not wait for resource policy"),
            Ok(None)
        );
    }
}
