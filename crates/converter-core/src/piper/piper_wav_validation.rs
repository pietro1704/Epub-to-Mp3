//! Validate native WAV payloads and publish WAV/MP3 atomically.
use super::PiperError;
use std::fs;
use std::path::{Path, PathBuf};

pub(super) fn validate_wav(path: &Path) -> Result<(), PiperError> {
    let wav_bytes = fs::read(path).map_err(|error| PiperError::InvalidWav(error.to_string()))?;
    if wav_bytes.len() < 44 || &wav_bytes[0..4] != b"RIFF" || &wav_bytes[8..12] != b"WAVE" {
        return Err(PiperError::InvalidWav("missing RIFF/WAVE header".into()));
    }
    if wav_bytes.len() <= 44 {
        return Err(PiperError::InvalidWav("audio payload is empty".into()));
    }
    Ok(())
}
pub(super) fn publish_piper_audio(wav: &Path, output: &Path) -> Result<PathBuf, PiperError> {
    validate_wav(wav)?;
    if output
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("mp3"))
    {
        encode_piper_mp3(wav, output)?;
    } else if wav != output {
        fs::rename(wav, output).map_err(|error| PiperError::Io(error.to_string()))?;
    }
    Ok(output.to_path_buf())
}

fn encode_piper_mp3(wav: &Path, output: &Path) -> Result<(), PiperError> {
    let wav_bytes = fs::read(wav).map_err(|error| PiperError::Io(error.to_string()))?;
    let encoded =
        crate::pcm::encode_wav_mp3_at_source_rate(&wav_bytes).map_err(PiperError::InvalidWav)?;
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|error| PiperError::Io(error.to_string()))?;
    let staging = tempfile::Builder::new()
        .prefix(".piper-mp3-")
        .tempdir_in(parent)
        .map_err(|error| PiperError::Io(error.to_string()))?;
    let staged = staging.path().join("speech.mp3");
    fs::write(&staged, encoded).map_err(|error| PiperError::Io(error.to_string()))?;
    let file = fs::File::open(&staged).map_err(|error| PiperError::Io(error.to_string()))?;
    file.sync_all()
        .map_err(|error| PiperError::Io(error.to_string()))?;
    fs::rename(staged, output).map_err(|error| PiperError::Io(error.to_string()))?;
    Ok(())
}
