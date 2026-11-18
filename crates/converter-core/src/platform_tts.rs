//! Platform speech adapter. Rust retains segmentation, encoding and publication.
use std::path::Path;

pub trait PlatformTts: Send + Sync {
    /// Backend display identity, never a claim about a resolved voice/cache key.
    fn backend_name(&self) -> &'static str {
        "installed system speech"
    }
    /// Write mono signed 16-bit PCM WAV. Poll cancellation while waiting for speech.
    fn synthesize_wav(
        &self,
        text: &str,
        language: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), String>;
}

pub(crate) fn segments_with_limit(
    text: &str,
    limit: usize,
) -> Result<Vec<String>, crate::tts_session::TtsFailure> {
    split_segments(text, 180.min(limit), limit)
}

fn split_segments(
    text: &str,
    initial: usize,
    subsequent: usize,
) -> Result<Vec<String>, crate::tts_session::TtsFailure> {
    crate::tts_session::segment_text(text, initial, subsequent)
}
