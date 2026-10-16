//! Platform speech adapter. Rust retains segmentation, encoding and publication.
use std::path::Path;

pub trait PlatformTts: Send + Sync {
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

/// Compact utterances keep legacy system voices below their per-call deadline.
pub(crate) fn native_segments(text: &str, first: bool) -> Vec<String> {
    split_segments(text, if first { 60 } else { 240 }, 240)
}

fn split_segments(text: &str, initial: usize, subsequent: usize) -> Vec<String> {
    let mut result = Vec::new();
    let mut pending = text.trim();
    while !pending.is_empty() {
        let limit = if result.is_empty() {
            initial
        } else {
            subsequent
        };
        let end = pending
            .char_indices()
            .nth(limit)
            .map(|(offset, _)| offset)
            .unwrap_or(pending.len());
        let prefix = &pending[..end];
        let boundary = if end == pending.len() {
            end
        } else {
            prefix
                .char_indices()
                .rev()
                .find(|(_, c)| c.is_whitespace() || matches!(c, '.' | '?' | '!'))
                .map(|(offset, c)| offset + c.len_utf8())
                .filter(|offset| *offset > end / 2)
                .unwrap_or(end)
        };
        result.push(pending[..boundary].trim().to_owned());
        pending = pending[boundary..].trim_start();
    }
    result
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
