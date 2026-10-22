//! Typed external audio commands and platform capability policy.
use super::AudioError;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

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

pub(super) fn run_audio_process(spec: &ProcessSpec) -> Result<Output, AudioError> {
    let program = resolve_program(&spec.program);
    let output = Command::new(&program)
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

fn resolve_program(program: &str) -> PathBuf {
    let override_name = match program {
        "ffprobe" => Some("FFPROBE"),
        "ffmpeg" => Some("FFMPEG"),
        _ => None,
    };
    let override_path = override_name.and_then(std::env::var_os).map(PathBuf::from);
    let path_directories = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|value| std::env::split_paths(&value).collect::<Vec<_>>())
        .collect::<Vec<_>>();

    #[cfg(target_os = "macos")]
    let fallback_directories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        .into_iter()
        .map(PathBuf::from)
        .collect::<Vec<_>>();
    #[cfg(not(target_os = "macos"))]
    let fallback_directories = Vec::new();

    resolve_program_in(
        program,
        override_path,
        path_directories,
        fallback_directories,
    )
}

pub(super) fn resolve_program_in(
    program: &str,
    override_path: Option<PathBuf>,
    path_directories: impl IntoIterator<Item = PathBuf>,
    fallback_directories: impl IntoIterator<Item = PathBuf>,
) -> PathBuf {
    if let Some(path) = override_path.filter(|path| path.is_file()) {
        return path;
    }
    let requested = Path::new(program);
    if requested.components().count() > 1 {
        return requested.to_path_buf();
    }
    path_directories
        .into_iter()
        .chain(fallback_directories)
        .map(|directory| directory.join(program))
        .find(|path| path.is_file())
        .unwrap_or_else(|| requested.to_path_buf())
}

pub(super) fn require_external_audio_support() -> Result<(), AudioError> {
    #[cfg(target_os = "ios")]
    return Err(AudioError::Validation(
        "this audio format requires a desktop editing capability".into(),
    ));
    #[cfg(not(target_os = "ios"))]
    Ok(())
}
