//! Encode, pad and concatenate audio, then publish validated output.
use super::audio_process::{run_audio_process, ProcessSpec};
use super::audio_validation::{probe_sample_rate, validate_audio};
use super::AudioError;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Padding {
    pub intro_ms: u64,
    pub outro_ms: u64,
    pub sample_rate: u32,
    pub channels: u16,
}
impl Default for Padding {
    fn default() -> Self {
        Self {
            intro_ms: 0,
            outro_ms: 500,
            sample_rate: 16_000,
            channels: 1,
        }
    }
}

fn atomic_replace(source: &Path, target: &Path) -> Result<(), AudioError> {
    let temp = target.with_extension(format!(
        "{}.tmp-{}",
        target
            .extension()
            .and_then(OsStr::to_str)
            .unwrap_or("audio"),
        std::process::id()
    ));
    fs::copy(source, &temp)?;
    let file = File::open(&temp)?;
    file.sync_all()?;
    fs::rename(temp, target)?;
    Ok(())
}

/// Encode WAV audio as mono MP3 and replace the output after validation.
pub fn wav_to_mp3(
    input: impl AsRef<Path>,
    output: impl AsRef<Path>,
    bitrate: &str,
) -> Result<(), AudioError> {
    let input = input.as_ref();
    let output = output.as_ref();
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new()
        .prefix(".encode-mp3-")
        .tempdir_in(parent)?;
    let encoded = staging.path().join("encoded.mp3");
    run_audio_process(&ProcessSpec::new("ffmpeg").args([
        "-y",
        "-i",
        &input.to_string_lossy(),
        "-vn",
        "-c:a",
        "libmp3lame",
        "-b:a",
        bitrate,
        "-ac",
        "1",
        "-f",
        "mp3",
        &encoded.to_string_lossy(),
    ]))?;
    validate_audio(&encoded, 100)?;
    let file = File::open(&encoded)?;
    file.sync_all()?;
    drop(file);
    fs::rename(encoded, output)?;
    Ok(())
}

pub fn add_silence_padding(
    path: impl AsRef<Path>,
    padding: Padding,
    bitrate: &str,
) -> Result<(), AudioError> {
    let path = path.as_ref();
    if padding.intro_ms == 0 && padding.outro_ms == 0 {
        return Ok(());
    }
    validate_audio(path, 100)?;
    let rate = probe_sample_rate(path).unwrap_or(padding.sample_rate);
    let temp = path.with_extension(format!("padded-{}.mp3", std::process::id()));
    let mut filters = Vec::new();
    if padding.intro_ms > 0 {
        filters.push(format!("adelay={}:all=1", padding.intro_ms));
    }
    if padding.outro_ms > 0 {
        filters.push(format!(
            "apad=pad_dur={:.3}",
            padding.outro_ms as f64 / 1000.0
        ));
    }
    run_audio_process(&ProcessSpec::new("ffmpeg").args([
        "-y",
        "-i",
        &path.to_string_lossy(),
        "-af",
        &filters.join(","),
        "-b:a",
        bitrate,
        "-ar",
        &rate.to_string(),
        "-ac",
        &padding.channels.to_string(),
        &temp.to_string_lossy(),
    ]))?;
    validate_audio(&temp, 100)?;
    atomic_replace(&temp, path)?;
    let _ = fs::remove_file(temp);
    Ok(())
}

pub fn concatenate(
    inputs: &[PathBuf],
    output: impl AsRef<Path>,
    bitrate: &str,
) -> Result<(), AudioError> {
    if inputs.is_empty() {
        return Err(AudioError::InvalidConfig("no audio inputs".into()));
    }
    let output = output.as_ref();
    let list = output.with_extension(format!("concat-{}.txt", std::process::id()));
    let temp = output.with_extension(format!("concat-{}.mp3", std::process::id()));
    let mut text = String::new();
    for input in inputs {
        validate_audio(input, 100)?;
        text.push_str(&format!("file '{} value'\n", input.display()).replace(" value", ""));
    }
    fs::write(&list, text)?;
    run_audio_process(&ProcessSpec::new("ffmpeg").args([
        "-y",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        &list.to_string_lossy(),
        "-c:a",
        "libmp3lame",
        "-b:a",
        bitrate,
        &temp.to_string_lossy(),
    ]))?;
    validate_audio(&temp, 100)?;
    atomic_replace(&temp, output)?;
    let _ = fs::remove_file(list);
    let _ = fs::remove_file(temp);
    Ok(())
}
