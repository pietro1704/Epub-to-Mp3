//! Stable machine codes for conversion failures.
//!
//! The human message of a [`WorkerError`] is unchanged. Clients that want to
//! localize a failure read a closed set of codes from an additive marker
//! appended to that message, the same convention as `book_language_uncertain_v1`:
//! `<message> [[error_code_v1]]<code>[[/error_code_v1]]`. Unknown codes must be
//! shown with the plain message, so the set can grow without breaking clients.
use super::WorkerError;
use crate::tts_session::FailureKind;

pub const ERROR_CODE_OPEN: &str = "[[error_code_v1]]";
pub const ERROR_CODE_CLOSE: &str = "[[/error_code_v1]]";

impl WorkerError {
    /// A stable, lowercase code for this failure.
    pub fn code(&self) -> &'static str {
        let message = self.to_string();
        // Failures that already carry their own marker keep a dedicated code.
        if message.contains("[[book_language_uncertain_v1]]") {
            return "book_language_uncertain";
        }
        if message.contains("[[edge_consent_required_v1]]") {
            return "edge_consent_required";
        }
        if message.contains("[[tts_language_mismatch_v1]]") {
            return "language_model_unavailable";
        }
        match self {
            // A text-less page with drawn content (often an image cover) needs
            // OCR; clients explain that instead of a generic unreadable input.
            // The integration test `pdf_image_only_page_failure_carries_the_ocr_required_code`
            // pins this to the real ingestion message.
            Self::BookInput(crate::book_input::BookInputError::Pdf(
                crate::ingestion::IngestionError::InvalidInput { message },
            )) if message.contains("OCR is required") => "pdf_ocr_required",
            Self::BookInput(_) | Self::Epub(_) => "input_unreadable",
            Self::Job(_) => "job_state",
            Self::Cache(_) => "storage",
            Self::Audio(_) => "audio_output",
            Self::Io(_) => "io",
            Self::Edge(_) => "edge_failed",
            Self::Piper(error) => piper_code(error),
            Self::InvalidSelection(_) => "invalid_selection",
            Self::Control(_) => "conversion_control",
            Self::NoReadableText => "no_readable_text",
            Self::TextCoverage { .. } => "text_coverage",
            Self::Synthesis(failure) => match failure.kind {
                FailureKind::Unavailable => "engine_unavailable",
                FailureKind::InvalidSelection => "invalid_selection",
                FailureKind::InvalidAudio => "invalid_audio",
                FailureKind::Synthesis => "synthesis_failed",
                FailureKind::RateLimited => "rate_limited",
                FailureKind::Cancelled => "cancelled",
                FailureKind::Replaced => "replaced",
            },
            Self::PlatformTts(_) => "platform_speech_failed",
            Self::Cancelled => "cancelled",
            Self::PlaybackWindowChanged => "playback_window_changed",
            Self::Unsupported(_) => "unsupported_input",
        }
    }

    /// The message followed by the additive error-code marker.
    pub fn message_with_code(&self) -> String {
        format!("{self} {ERROR_CODE_OPEN}{}{ERROR_CODE_CLOSE}", self.code())
    }
}

fn piper_code(error: &crate::piper::PiperError) -> &'static str {
    use crate::piper::PiperError;
    match error {
        PiperError::RuntimeUnavailable(_) | PiperError::IncompatibleAbi(_) => "engine_unavailable",
        PiperError::MissingModel(_) | PiperError::MissingConfig(_) => "model_missing",
        PiperError::EmptyOutput | PiperError::Synthesis(_) => "synthesis_failed",
        PiperError::InvalidWav(_) => "invalid_audio",
        PiperError::Timeout => "synthesis_timeout",
        PiperError::Cancelled => "cancelled",
        PiperError::Io(_) => "io",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{piper::PiperError, tts_session::TtsFailure};

    fn code(error: WorkerError) -> &'static str {
        error.code()
    }

    #[test]
    fn typed_failures_have_stable_codes() {
        assert_eq!(code(WorkerError::NoReadableText), "no_readable_text");
        assert_eq!(code(WorkerError::Cancelled), "cancelled");
        assert_eq!(
            code(WorkerError::PlaybackWindowChanged),
            "playback_window_changed"
        );
        assert_eq!(
            code(WorkerError::Unsupported("x".into())),
            "unsupported_input"
        );
        assert_eq!(
            code(WorkerError::InvalidSelection("x".into())),
            "invalid_selection"
        );
        assert_eq!(
            code(WorkerError::PlatformTts("x".into())),
            "platform_speech_failed"
        );
        assert_eq!(
            code(WorkerError::TextCoverage {
                source_chars: 1,
                output_chars: 2
            }),
            "text_coverage"
        );
        assert_eq!(code(WorkerError::Io(std::io::Error::other("x"))), "io");
    }

    #[test]
    fn synthesis_failures_map_by_kind() {
        for (kind, expected) in [
            (FailureKind::Unavailable, "engine_unavailable"),
            (FailureKind::InvalidSelection, "invalid_selection"),
            (FailureKind::InvalidAudio, "invalid_audio"),
            (FailureKind::Synthesis, "synthesis_failed"),
            (FailureKind::RateLimited, "rate_limited"),
            (FailureKind::Cancelled, "cancelled"),
            (FailureKind::Replaced, "replaced"),
        ] {
            assert_eq!(
                code(WorkerError::Synthesis(TtsFailure::new(kind, "m"))),
                expected
            );
        }
    }

    #[test]
    fn piper_failures_distinguish_a_missing_model_from_an_unavailable_runtime() {
        assert_eq!(
            code(WorkerError::Piper(PiperError::MissingModel(
                "m.onnx".into()
            ))),
            "model_missing"
        );
        assert_eq!(
            code(WorkerError::Piper(PiperError::RuntimeUnavailable(
                "x".into()
            ))),
            "engine_unavailable"
        );
        assert_eq!(
            code(WorkerError::Piper(PiperError::Timeout)),
            "synthesis_timeout"
        );
    }

    #[test]
    fn existing_markers_keep_dedicated_codes() {
        let uncertain = WorkerError::Unsupported(
            "inconclusive [[book_language_uncertain_v1]]{}[[/book_language_uncertain_v1]]".into(),
        );
        assert_eq!(code(uncertain), "book_language_uncertain");
        let mismatch = WorkerError::Synthesis(TtsFailure::new(
            FailureKind::Unavailable,
            "no voice [[tts_language_mismatch_v1]]{}[[/tts_language_mismatch_v1]]",
        ));
        assert_eq!(code(mismatch), "language_model_unavailable");
        let consent = WorkerError::InvalidSelection(
            "Edge needs consent [[edge_consent_required_v1]]{}[[/edge_consent_required_v1]]".into(),
        );
        assert_eq!(code(consent), "edge_consent_required");
    }

    #[test]
    fn the_message_is_unchanged_and_the_marker_is_appended_once() {
        let error = WorkerError::NoReadableText;
        let text = error.message_with_code();
        assert_eq!(
            text,
            "selected chapters have no readable text [[error_code_v1]]no_readable_text[[/error_code_v1]]"
        );
        assert!(text.starts_with(&error.to_string()));
        assert_eq!(text.matches(ERROR_CODE_OPEN).count(), 1);
    }
}
