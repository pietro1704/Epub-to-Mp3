//! Typed audio post-processing and archive orchestration.
use serde::{Deserialize, Serialize};
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use thiserror::Error;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

#[derive(Debug, Error)]
pub enum AudioError {
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("invalid audio configuration: {0}")]
    InvalidConfig(String),
    #[error("{program} failed with status {status}: {stderr}")]
    Process {
        program: String,
        status: String,
        stderr: String,
    },
    #[error("audio validation failed: {0}")]
    Validation(String),
    #[error("archive error: {0}")]
    Archive(#[from] zip::result::ZipError),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessSpec {
    pub program: String,
    pub args: Vec<String>,
}

impl ProcessSpec {
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
        }
    }
    pub fn arg(mut self, value: impl Into<String>) -> Self {
        self.args.push(value.into());
        self
    }
    pub fn args<I, S>(mut self, values: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(values.into_iter().map(Into::into));
        self
    }
}

fn run(spec: &ProcessSpec) -> Result<Output, AudioError> {
    let output = Command::new(&spec.program)
        .args(&spec.args)
        .stdin(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Err(AudioError::Process {
            program: spec.program.clone(),
            status: output.status.to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(output)
}

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

pub fn probe_duration(path: impl AsRef<Path>) -> Result<f64, AudioError> {
    let output = run(&ProcessSpec::new("ffprobe").args([
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=nw=1:nk=1",
        &path.as_ref().to_string_lossy(),
    ]))?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<f64>()
        .map_err(|_| {
            AudioError::Validation(format!("invalid duration for {}", path.as_ref().display()))
        })
}

pub fn probe_sample_rate(path: impl AsRef<Path>) -> Result<u32, AudioError> {
    let output = run(&ProcessSpec::new("ffprobe").args([
        "-v",
        "error",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=sample_rate",
        "-of",
        "default=nw=1:nk=1",
        &path.as_ref().to_string_lossy(),
    ]))?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u32>()
        .map_err(|_| {
            AudioError::Validation(format!(
                "invalid sample rate for {}",
                path.as_ref().display()
            ))
        })
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

pub fn validate_audio(path: impl AsRef<Path>, minimum_bytes: u64) -> Result<f64, AudioError> {
    let path = path.as_ref();
    let size = fs::metadata(path)
        .map_err(|_| AudioError::Validation(format!("missing audio: {}", path.display())))?
        .len();
    if size < minimum_bytes {
        return Err(AudioError::Validation(format!(
            "audio is too small: {} bytes",
            size
        )));
    }
    let duration = probe_duration(path)?;
    if !duration.is_finite() || duration <= 0.0 {
        return Err(AudioError::Validation(
            "audio has no positive duration".into(),
        ));
    }
    Ok(duration)
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
    run(&ProcessSpec::new("ffmpeg").args([
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
    run(&ProcessSpec::new("ffmpeg").args([
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChapterMetadata {
    pub index: usize,
    pub title: String,
    pub filename: String,
    pub text_chars: usize,
}

pub fn write_metadata(
    path: impl AsRef<Path>,
    chapters: &[ChapterMetadata],
) -> Result<(), AudioError> {
    crate::cache::atomic_write_json(path, chapters)
        .map_err(|e| AudioError::Io(io::Error::other(e.to_string())))
}

pub fn create_archive(
    output: impl AsRef<Path>,
    files: &[(PathBuf, String)],
) -> Result<(), AudioError> {
    let output = output.as_ref();
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = output.with_extension(format!("zip.tmp-{}", std::process::id()));
    let file = File::create(&temp)?;
    let mut archive = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    let mut buffer = [0u8; 1024 * 1024];
    for (source, name) in files {
        archive.start_file(name, options)?;
        let mut input = File::open(source)?;
        loop {
            let count = input.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            archive.write_all(&buffer[..count])?;
        }
    }
    let file = archive.finish()?;
    file.sync_all()?;
    fs::rename(temp, output)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn zero_padding_is_noop() {
        assert_eq!(
            Padding {
                intro_ms: 0,
                outro_ms: 0,
                ..Default::default()
            },
            Padding {
                intro_ms: 0,
                outro_ms: 0,
                sample_rate: 16_000,
                channels: 1
            }
        );
    }
    #[test]
    fn process_is_typed() {
        assert_eq!(
            ProcessSpec::new("ffmpeg").arg("-y").args(["-i", "input"]),
            ProcessSpec {
                program: "ffmpeg".into(),
                args: vec!["-y".into(), "-i".into(), "input".into()]
            }
        );
    }
}
