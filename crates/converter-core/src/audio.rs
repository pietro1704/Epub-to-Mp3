use std::path::{Path, PathBuf};

use crate::{AudioFormat, PlannedChapter};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioRequest {
    pub chapter: PlannedChapter,
    pub output: PathBuf,
}

impl AudioRequest {
    pub fn new(chapter: PlannedChapter, output_directory: impl AsRef<Path>) -> Self {
        Self {
            output: output_directory.as_ref().join(&chapter.output_filename),
            chapter,
        }
    }

    pub fn format(&self) -> Option<AudioFormat> {
        self.output
            .extension()
            .and_then(|extension| extension.to_str())
            .and_then(|extension| extension.parse().ok())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioArtifact {
    pub path: PathBuf,
    pub format: AudioFormat,
    pub duration_millis: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AudioError {
    InvalidOutputFormat,
    BackendUnavailable(String),
    SynthesisFailed(String),
}

impl std::fmt::Display for AudioError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidOutputFormat => formatter.write_str("audio output format is invalid"),
            Self::BackendUnavailable(message) => {
                write!(formatter, "audio backend unavailable: {message}")
            }
            Self::SynthesisFailed(message) => {
                write!(formatter, "audio synthesis failed: {message}")
            }
        }
    }
}

impl std::error::Error for AudioError {}

pub trait AudioBackend: Send + Sync {
    fn synthesize(&self, request: &AudioRequest) -> Result<AudioArtifact, AudioError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::AudioFormat;

    #[test]
    fn builds_an_audio_request_from_a_planned_chapter() {
        let chapter = PlannedChapter {
            index: "1".to_owned(),
            title: "Opening".to_owned(),
            text: "Text".to_owned(),
            output_filename: "1 - Opening.m4a".to_owned(),
        };
        let request = AudioRequest::new(chapter, "/tmp/book");
        assert_eq!(request.output, PathBuf::from("/tmp/book/1 - Opening.m4a"));
        assert_eq!(request.format(), Some(AudioFormat::M4a));
    }
}
