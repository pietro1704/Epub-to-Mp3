//! Portable listening intent and time-based prefetch policy. No provider branches.
use super::{FailureKind, TtsFailure, CONTRACT_VERSION};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListeningPosition {
    pub version: u32,
    pub chapter_index: usize,
    /// Unicode scalar offset in the normalized source chapter, never an audio byte offset.
    pub text_offset: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlaybackFeedback {
    #[serde(default)]
    pub generation: Option<u64>,
    pub version: u32,
    pub chapter_index: usize,
    pub remaining_audio_seconds: f64,
    pub playback_rate: f64,
}

#[derive(Debug, Clone)]
pub struct ListeningPlan {
    pub position: ListeningPosition,
    pub generation: u64,
    prefetch: bool,
    prefix_generation_seconds: f64,
}

impl ListeningPlan {
    pub fn new(position: ListeningPosition) -> Result<Self, TtsFailure> {
        if position.version != CONTRACT_VERSION {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Unsupported listening contract",
            ));
        }
        Ok(Self {
            position,
            generation: 0,
            prefetch: false,
            prefix_generation_seconds: 30.0,
        })
    }

    pub fn move_to(&mut self, position: ListeningPosition) -> Result<bool, TtsFailure> {
        Self::new(position.clone())?;
        if self.position == position {
            return Ok(false);
        }
        self.position = position;
        self.generation = self.generation.wrapping_add(1);
        self.prefetch = false;
        Ok(true)
    }

    pub fn feedback(&mut self, feedback: &PlaybackFeedback) -> Result<(), TtsFailure> {
        if feedback.version != CONTRACT_VERSION
            || !feedback.remaining_audio_seconds.is_finite()
            || feedback.remaining_audio_seconds < 0.0
            || !feedback.playback_rate.is_finite()
            || !(0.25..=4.0).contains(&feedback.playback_rate)
        {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Invalid playback timing",
            ));
        }
        if feedback.chapter_index != self.position.chapter_index
            || feedback.generation != Some(self.generation)
        {
            return Err(TtsFailure::new(
                FailureKind::Replaced,
                "Feedback belongs to an old chapter",
            ));
        }
        // Once preparation starts, extending a duration estimate must not cancel it.
        self.prefetch |= feedback.remaining_audio_seconds / feedback.playback_rate
            <= (self.prefix_generation_seconds * 1.5).max(5.0);
        Ok(())
    }

    pub fn observe_generation(&mut self, seconds: f64, text_chars: usize) {
        if seconds.is_finite() && seconds > 0.0 && text_chars > 0 {
            // Predict the next short prefix, including session/model startup cost.
            self.prefix_generation_seconds =
                (seconds * 480.0 / text_chars as f64).clamp(0.1, 300.0);
        }
    }

    pub fn permits(&self, chapter: usize) -> bool {
        chapter == self.position.chapter_index
            || (self.prefetch && chapter == self.position.chapter_index.saturating_add(1))
    }

    pub fn remaining_text<'a>(
        &self,
        chapter: usize,
        text: &'a str,
    ) -> Result<(&'a str, usize), TtsFailure> {
        let offset = if chapter == self.position.chapter_index {
            self.position.text_offset
        } else {
            0
        };
        if !text.is_empty() && offset >= text.chars().count() {
            return Err(TtsFailure::new(
                FailureKind::InvalidSelection,
                "Listening offset must identify source text before chapter end",
            ));
        }
        let byte = text
            .char_indices()
            .nth(offset)
            .map(|(byte, _)| byte)
            .or_else(|| (offset == text.chars().count()).then_some(text.len()))
            .ok_or_else(|| {
                TtsFailure::new(
                    FailureKind::InvalidSelection,
                    "Listening offset exceeds source text",
                )
            })?;
        Ok((&text[byte..], offset))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn position(chapter_index: usize, text_offset: usize) -> ListeningPosition {
        ListeningPosition {
            version: 2,
            chapter_index,
            text_offset,
        }
    }
    #[test]
    fn chapter_only_then_prefetch_follows_audio_time_rate_and_measured_generation() {
        let mut plan = ListeningPlan::new(position(3, 0)).unwrap();
        assert!(plan.permits(3));
        assert!(!plan.permits(4));
        plan.observe_generation(8.0, 480);
        let mut feedback = PlaybackFeedback {
            generation: Some(0),
            version: 2,
            chapter_index: 3,
            remaining_audio_seconds: 20.0,
            playback_rate: 1.0,
        };
        plan.feedback(&feedback).unwrap();
        assert!(!plan.permits(4));
        feedback.playback_rate = 2.0;
        plan.feedback(&feedback).unwrap();
        assert!(plan.permits(4));
        assert!(!plan.permits(5));
    }
    #[test]
    fn seek_retires_generation_and_old_feedback_without_losing_unicode_range() {
        let mut plan = ListeningPlan::new(position(1, 2)).unwrap();
        assert_eq!(plan.remaining_text(1, "á🙂texto").unwrap(), ("texto", 2));
        let generation = plan.generation;
        assert!(plan.move_to(position(1, 3)).unwrap());
        assert_ne!(plan.generation, generation);
        assert!(plan.move_to(position(2, 0)).unwrap());
        assert!(!plan.permits(1));
        assert_eq!(
            plan.feedback(&PlaybackFeedback {
                generation: Some(0),
                version: 2,
                chapter_index: 1,
                remaining_audio_seconds: 0.0,
                playback_rate: 1.0
            })
            .unwrap_err()
            .kind,
            FailureKind::Replaced
        );
        assert!(plan.remaining_text(2, "abc").is_ok());
    }
    #[test]
    fn malformed_timing_and_out_of_range_offsets_fail_closed() {
        let mut plan = ListeningPlan::new(position(0, 9)).unwrap();
        assert!(plan.remaining_text(0, "á🙂").is_err());
        let eof = ListeningPlan::new(position(0, 2)).unwrap();
        assert!(eof.remaining_text(0, "á🙂").is_err());
        assert_eq!(
            ListeningPlan::new(position(0, 1))
                .unwrap()
                .remaining_text(0, "á🙂")
                .unwrap(),
            ("🙂", 1)
        );
        for seconds in [f64::NAN, f64::INFINITY, -1.0] {
            assert!(plan
                .feedback(&PlaybackFeedback {
                    generation: Some(0),
                    version: 2,
                    chapter_index: 0,
                    remaining_audio_seconds: seconds,
                    playback_rate: 1.0
                })
                .is_err());
        }
        assert!(!plan.permits(1));
    }
}
