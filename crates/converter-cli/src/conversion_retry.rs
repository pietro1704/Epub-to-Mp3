//! Whole-job retry rounds around the embedded worker.
//!
//! The core already recovers inside a chapter (primary voice, configured
//! secondary, bounded native fallback) and stops the job at the first chapter
//! that still fails. A retry round runs the same job again: chapters whose
//! completion receipt validates are reused and the failed chapter is attempted
//! again, so a round does not repeat finished work. `--force-reprocess` is the
//! exception: it stays in force for every round, because relaxing it would let
//! the failed chapter fall back to the cached audio the user asked to ignore.
use super::CliOptions;
use converter_core::embedded::{EmbeddedConversionError, EmbeddedConversionSession};
use converter_core::worker::{OutputManifest, WorkerError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct RetryRounds {
    pub(super) automatic: u32,
    /// One extra pass after the automatic rounds.
    pub(super) manual: bool,
}

impl RetryRounds {
    pub(super) fn from_options(options: &CliOptions) -> Self {
        Self {
            automatic: options.retry_failed_rounds.unwrap_or(0),
            manual: options.retry_failed_manual,
        }
    }
}

/// Failures that another round can change. A rejected request, an unreadable
/// source or a job-store conflict would fail identically, and retrying a job
/// this invocation does not own could disturb another worker.
fn retryable(error: &EmbeddedConversionError) -> bool {
    match error {
        EmbeddedConversionError::Conversion(WorkerError::Synthesis(failure)) => {
            !failure.terminal()
                && failure.kind != converter_core::tts_session::FailureKind::InvalidSelection
        }
        EmbeddedConversionError::Conversion(error) => !matches!(
            error,
            WorkerError::Cancelled
                | WorkerError::Piper(converter_core::piper::PiperError::Cancelled)
                | WorkerError::PlaybackWindowChanged
                | WorkerError::Unsupported(_)
                | WorkerError::BookInput(_)
                | WorkerError::Epub(_)
                | WorkerError::Job(_)
                | WorkerError::InvalidSelection(_)
                | WorkerError::Control(_)
                | WorkerError::NoReadableText
                | WorkerError::TextCoverage { .. }
        ),
        _ => false,
    }
}

pub(super) fn run_with_retry_rounds(
    session: &EmbeddedConversionSession,
    rounds: RetryRounds,
    first_attempt: impl FnOnce(
        &EmbeddedConversionSession,
    ) -> Result<OutputManifest, EmbeddedConversionError>,
) -> Result<OutputManifest, String> {
    let mut result = first_attempt(session);
    for round in 1..=rounds.automatic.saturating_add(u32::from(rounds.manual)) {
        let Err(error) = &result else { break };
        if !retryable(error) {
            break;
        }
        if round > rounds.automatic {
            eprintln!("manual retry pass after failure: {error}");
        } else {
            eprintln!(
                "retry round {round}/{} after failure: {error}",
                rounds.automatic
            );
        }
        result = session.retry_failed();
    }
    result.map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_failures_another_round_can_change_are_retried() {
        let conversion = EmbeddedConversionError::Conversion;
        for transient in [
            WorkerError::Piper(converter_core::piper::PiperError::Synthesis(
                "synthesis failed".into(),
            )),
            WorkerError::PlatformTts("voice unavailable".into()),
            WorkerError::Io(std::io::Error::other("disk")),
        ] {
            assert!(retryable(&conversion(transient)));
        }
        for permanent in [
            WorkerError::Cancelled,
            WorkerError::Piper(converter_core::piper::PiperError::Cancelled),
            WorkerError::PlaybackWindowChanged,
            WorkerError::Unsupported("language".into()),
            WorkerError::Job(converter_core::jobs::JobError::InvalidJobId),
            WorkerError::InvalidSelection("voice language".into()),
            WorkerError::Control(
                converter_core::conversion_control::ConversionControlError::AlreadyAttached,
            ),
            WorkerError::NoReadableText,
            WorkerError::TextCoverage {
                source_chars: 10,
                output_chars: 9,
            },
            WorkerError::Synthesis(converter_core::tts_session::TtsFailure::new(
                converter_core::tts_session::FailureKind::InvalidSelection,
                "voice",
            )),
        ] {
            assert!(!retryable(&conversion(permanent)));
        }
        assert!(!retryable(&EmbeddedConversionError::ReadInput {
            path: "missing.epub".into(),
            source: std::io::Error::other("missing"),
        }));
    }
}
