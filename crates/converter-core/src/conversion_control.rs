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
    selected: Vec<usize>,
    paused: bool,
    recovery_job: Option<String>,
    playback_window: Option<(usize, usize)>,
    listening: Option<crate::tts_session::ListeningPlan>,
}

pub(crate) struct GenerationLease<'a> {
    _queue: std::sync::MutexGuard<'a, QueueState>,
}

/// Shared only by one conversion invocation and its native control handle.
#[derive(Clone, Default)]
pub struct ConversionControl {
    cancel: CancellationToken,
    queue: Arc<Mutex<QueueState>>,
    ready: Arc<Condvar>,
}

impl ConversionControl {
    pub(crate) fn lease_generation(
        &self,
        generation: Option<u64>,
        chapter: Option<usize>,
    ) -> Result<GenerationLease<'_>, String> {
        let queue = self
            .queue
            .lock()
            .map_err(|_| "Conversion control lock poisoned")?;
        let permitted = chapter.is_none_or(|chapter| {
            queue.listening.as_ref().map_or_else(
                || {
                    queue.playback_window.is_none_or(|(start, ahead)| {
                        chapter >= start && chapter <= start.saturating_add(ahead)
                    })
                },
                |plan| plan.permits(chapter),
            )
        });
        if self.cancel.is_cancelled()
            || !permitted
            || queue.listening.as_ref().map(|plan| plan.generation) != generation
        {
            return Err("Listening generation was replaced or cancelled".into());
        }
        Ok(GenerationLease { _queue: queue })
    }
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

    /// Restrict playback conversion to the current source chapter and a small
    /// number of chapters ahead. Unselected work remains pending for navigation.
    pub fn set_playback_window(&self, current_chapter: usize, chapters_ahead: usize) {
        let mut queue = self.queue.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(plan) = &mut queue.listening {
            if plan.position.chapter_index != current_chapter {
                let _ = plan.move_to(crate::tts_session::ListeningPosition {
                    version: 2,
                    chapter_index: current_chapter,
                    text_offset: 0,
                });
                if queue.selected.contains(&current_chapter)
                    && !queue.remaining.contains(&current_chapter)
                {
                    queue.remaining.push_front(current_chapter);
                }
            }
        }
        queue.playback_window = Some((current_chapter, chapters_ahead));
        self.ready.notify_all();
    }

    pub fn chapter_is_in_playback_window(&self, chapter_index: usize) -> bool {
        let queue = self.queue.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(plan) = &queue.listening {
            return plan.permits(chapter_index);
        }
        queue.playback_window.is_none_or(|(start, ahead)| {
            chapter_index >= start && chapter_index <= start.saturating_add(ahead)
        })
    }

    pub(crate) fn requeue(&self, chapter_index: usize) -> Result<(), ConversionControlError> {
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| ConversionControlError::LockPoisoned)?;
        if !queue.remaining.contains(&chapter_index) {
            queue.remaining.push_back(chapter_index);
        }
        self.ready.notify_all();
        Ok(())
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
        if let Some(plan) = &queue.listening {
            if !selected.contains(&plan.position.chapter_index) {
                return Err(ConversionControlError::UnavailableChapter(
                    plan.position.chapter_index,
                ));
            }
        }
        queue.selected = selected.to_vec();
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
        loop {
            let eligible = queue.remaining.iter().position(|source_index| {
                if let Some(plan) = &queue.listening {
                    return plan.permits(*source_index);
                }
                queue.playback_window.is_none_or(|(start, ahead)| {
                    *source_index >= start && *source_index <= start.saturating_add(ahead)
                })
            });
            if self.cancel.is_cancelled() || (!queue.paused && eligible.is_some()) {
                return Ok(eligible.map(|position| queue.remaining.remove(position).unwrap()));
            }
            if queue.remaining.is_empty() {
                return Ok(None);
            }
            queue = self
                .ready
                .wait(queue)
                .map_err(|_| ConversionControlError::LockPoisoned)?;
        }
    }
}

impl ConversionControl {
    pub fn set_listening_position(
        &self,
        position: crate::tts_session::ListeningPosition,
    ) -> Result<(), String> {
        if self.cancel.is_cancelled() {
            return Err("Conversion cancelled".into());
        }
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| "Conversion control lock poisoned")?;
        let chapter = position.chapter_index;
        if queue.attached && !queue.selected.contains(&chapter) {
            return Err("Listening chapter is outside this job selection".into());
        }
        let changed = if let Some(plan) = &mut queue.listening {
            plan.move_to(position).map_err(|error| error.to_string())?
        } else {
            queue.listening = Some(
                crate::tts_session::ListeningPlan::new(position)
                    .map_err(|error| error.to_string())?,
            );
            true
        };
        if changed && queue.attached && !queue.remaining.contains(&chapter) {
            queue.remaining.push_front(chapter);
        }
        self.ready.notify_all();
        Ok(())
    }

    pub fn playback_feedback(
        &self,
        feedback: &crate::tts_session::PlaybackFeedback,
    ) -> Result<(), String> {
        if self.cancel.is_cancelled() {
            return Err("Conversion cancelled".into());
        }
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| "Conversion control lock poisoned")?;
        queue
            .listening
            .as_mut()
            .ok_or("No listening position selected")?
            .feedback(feedback)
            .map_err(|error| error.to_string())?;
        self.ready.notify_all();
        Ok(())
    }

    pub fn listening_plan(&self) -> Option<crate::tts_session::ListeningPlan> {
        self.queue
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .listening
            .clone()
    }

    pub fn generation_is_current(&self, generation: Option<u64>) -> bool {
        self.listening_plan().as_ref().map(|plan| plan.generation) == generation
    }

    pub fn observe_generation_at(
        &self,
        generation: Option<u64>,
        seconds: f64,
        chars: usize,
    ) -> bool {
        let mut queue = self.queue.lock().unwrap_or_else(|error| error.into_inner());
        if self.cancel.is_cancelled() || !seconds.is_finite() || seconds <= 0.0 || chars == 0 {
            return false;
        }
        let Some(plan) = queue.listening.as_mut() else {
            return false;
        };
        if generation != Some(plan.generation) {
            return false;
        }
        plan.observe_generation(seconds, chars);
        true
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
    fn playback_window_holds_distant_chapters_and_moves_with_navigation() {
        let control = ConversionControl::new();
        control.set_playback_window(3, 1);
        control.attach(&[0, 1, 2, 3, 4, 5, 6]).unwrap();
        assert_eq!(control.take().unwrap(), Some(3));
        assert_eq!(control.take().unwrap(), Some(4));

        let waiting = control.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || tx.send(waiting.take().unwrap()).unwrap());
        assert!(rx
            .recv_timeout(std::time::Duration::from_millis(20))
            .is_err());
        control.set_playback_window(5, 1);
        assert_eq!(
            rx.recv_timeout(std::time::Duration::from_secs(1)).unwrap(),
            Some(5)
        );
        worker.join().unwrap();
        assert_eq!(control.take().unwrap(), Some(6));
    }

    #[test]
    fn playback_window_can_reject_an_in_flight_chapter_and_requeue_it() {
        let control = ConversionControl::new();
        control.set_playback_window(0, 1);
        control.attach(&[0, 1, 2]).unwrap();
        assert_eq!(control.take().unwrap(), Some(0));
        assert!(control.chapter_is_in_playback_window(0));

        control.set_playback_window(2, 1);
        assert!(!control.chapter_is_in_playback_window(0));
        control.requeue(0).unwrap();
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
