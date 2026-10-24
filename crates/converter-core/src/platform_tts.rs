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

/// Small initial utterance bounds startup work; later utterances bound memory.
pub(crate) fn segments(text: &str) -> Vec<String> {
    split_segments(text, 180, 800)
}

pub(crate) fn segments_with_limit(text: &str, limit: usize) -> Vec<String> {
    split_segments(text, 180.min(limit), limit)
}

/// Compact utterances keep legacy system voices below their per-call deadline.
pub(crate) fn native_segments(text: &str, first: bool) -> Vec<String> {
    split_segments(text, if first { 60 } else { 240 }, 240)
}

fn split_segments(text: &str, initial: usize, subsequent: usize) -> Vec<String> {
    crate::tts_session::segment_text(text, initial, subsequent).expect("validated text capacities")
}

/// Shared codec retains native RIFF validation and normalized 24 kHz MP3 output.
pub(crate) fn encode_wav(data: &[u8]) -> Result<Vec<u8>, String> {
    crate::pcm::encode_wav_mp3(data)
}

pub(crate) fn validate_mp3(bytes: &[u8]) -> Result<(), String> {
    crate::pcm::validate_mp3(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_segments_preserve_words_and_bound_startup() {
        let text = "Olá, ação e coração. ".repeat(150);
        let pieces = segments(&text);
        assert!(pieces[0].chars().count() <= 180);
        assert!(pieces.iter().all(|piece| piece.chars().count() <= 800));
        assert_eq!(pieces.join(" "), text.trim());
    }
    #[test]
    fn malformed_audio_is_rejected() {
        assert!(encode_wav(b"RIFF").is_err());
        assert!(validate_mp3(b"not audio").is_err());
    }
}
