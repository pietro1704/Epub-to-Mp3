//! Stable domain types shared by the CLI, HTTP adapter, Linux GUI and Android bridge.

pub mod audio;
pub mod epub;
pub mod pipeline;

use std::fmt;
use std::path::Path;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AudioFormat {
    Mp3,
    M4a,
}

impl AudioFormat {
    pub fn extension(self) -> &'static str {
        match self {
            Self::Mp3 => "mp3",
            Self::M4a => "m4a",
        }
    }
}

impl fmt::Display for AudioFormat {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.extension())
    }
}

impl std::str::FromStr for AudioFormat {
    type Err = DomainError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value
            .trim()
            .trim_start_matches('.')
            .to_ascii_lowercase()
            .as_str()
        {
            "mp3" => Ok(Self::Mp3),
            "m4a" => Ok(Self::M4a),
            other => Err(DomainError::UnsupportedAudioFormat(other.to_owned())),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Engine {
    Auto,
    Edge,
    Piper,
}

impl std::str::FromStr for Engine {
    type Err = DomainError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "auto" => Ok(Self::Auto),
            "edge" => Ok(Self::Edge),
            "piper" => Ok(Self::Piper),
            other => Err(DomainError::UnsupportedEngine(other.to_owned())),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversionOptions {
    pub engine: Engine,
    pub audio_format: AudioFormat,
}

impl Default for ConversionOptions {
    fn default() -> Self {
        Self {
            engine: Engine::Auto,
            audio_format: AudioFormat::Mp3,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlannedChapter {
    pub index: String,
    pub title: String,
    pub text: String,
    pub output_filename: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversionPlan {
    pub title: String,
    pub author: Option<String>,
    pub options: ConversionOptions,
    pub chapters: Vec<PlannedChapter>,
}

impl ConversionPlan {
    pub fn from_book(
        book: &BookStructure,
        options: ConversionOptions,
    ) -> Result<Self, DomainError> {
        if !book.is_narratable() {
            return Err(DomainError::EmptyInput);
        }
        let chapters = book
            .chapters
            .iter()
            .map(|chapter| PlannedChapter {
                index: chapter.index.clone(),
                title: chapter.title.clone(),
                text: chapter.text.clone(),
                output_filename: chapter.output_filename(options.audio_format),
            })
            .collect();
        Ok(Self {
            title: book.title.clone(),
            author: book.author.clone(),
            options,
            chapters,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Chapter {
    pub index: String,
    pub title: String,
    pub text: String,
}

impl Chapter {
    pub fn output_filename(&self, format: AudioFormat) -> String {
        format!(
            "{} - {}.{}",
            self.index,
            sanitize_filename(&self.title),
            format.extension()
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BookStructure {
    pub title: String,
    pub author: Option<String>,
    pub chapters: Vec<Chapter>,
}

impl BookStructure {
    pub fn is_narratable(&self) -> bool {
        !self.chapters.is_empty()
            && self
                .chapters
                .iter()
                .any(|chapter| !chapter.text.trim().is_empty())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum JobState {
    Queued,
    Running,
    Finished,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JobSnapshot {
    pub job_id: String,
    pub state: JobState,
    pub chapters_completed: usize,
    pub chapters_total: usize,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversionJob {
    id: String,
    state: JobState,
    chapters_completed: usize,
    chapters_total: usize,
    error: Option<String>,
}

impl ConversionJob {
    pub fn new(id: impl Into<String>, chapters_total: usize) -> Self {
        Self {
            id: id.into(),
            state: JobState::Queued,
            chapters_completed: 0,
            chapters_total,
            error: None,
        }
    }

    pub fn start(&mut self) -> Result<(), DomainError> {
        if self.state != JobState::Queued {
            return Err(DomainError::InvalidJobTransition);
        }
        self.state = JobState::Running;
        Ok(())
    }

    pub fn complete_chapter(&mut self) -> Result<(), DomainError> {
        if self.state != JobState::Running || self.chapters_completed >= self.chapters_total {
            return Err(DomainError::InvalidJobTransition);
        }
        self.chapters_completed += 1;
        Ok(())
    }

    pub fn finish(&mut self) -> Result<(), DomainError> {
        if self.state != JobState::Running || self.chapters_completed != self.chapters_total {
            return Err(DomainError::InvalidJobTransition);
        }
        self.state = JobState::Finished;
        Ok(())
    }

    pub fn fail(&mut self, message: impl Into<String>) -> Result<(), DomainError> {
        if matches!(
            self.state,
            JobState::Finished | JobState::Failed | JobState::Cancelled
        ) {
            return Err(DomainError::InvalidJobTransition);
        }
        self.error = Some(message.into());
        self.state = JobState::Failed;
        Ok(())
    }

    pub fn cancel(&mut self) -> Result<(), DomainError> {
        if matches!(
            self.state,
            JobState::Finished | JobState::Failed | JobState::Cancelled
        ) {
            return Err(DomainError::InvalidJobTransition);
        }
        self.state = JobState::Cancelled;
        Ok(())
    }

    pub fn snapshot(&self) -> JobSnapshot {
        JobSnapshot {
            job_id: self.id.clone(),
            state: self.state.clone(),
            chapters_completed: self.chapters_completed,
            chapters_total: self.chapters_total,
            error: self.error.clone(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DomainError {
    UnsupportedAudioFormat(String),
    UnsupportedEngine(String),
    EmptyInput,
    InvalidJobTransition,
}

impl fmt::Display for DomainError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedAudioFormat(value) => {
                write!(formatter, "unsupported audio format: {value}")
            }
            Self::UnsupportedEngine(value) => write!(formatter, "unsupported engine: {value}"),
            Self::EmptyInput => formatter.write_str("input path cannot be empty"),
            Self::InvalidJobTransition => {
                formatter.write_str("invalid conversion job state transition")
            }
        }
    }
}

impl std::error::Error for DomainError {}

pub fn validate_input_path(path: &Path) -> Result<(), DomainError> {
    if path.as_os_str().is_empty() {
        Err(DomainError::EmptyInput)
    } else {
        Ok(())
    }
}

fn sanitize_filename(value: &str) -> String {
    let sanitized: String = value
        .chars()
        .map(|character| match character {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            character if character.is_control() => '_',
            character => character,
        })
        .collect();
    let trimmed = sanitized.trim().trim_matches('.');
    if trimmed.is_empty() {
        "chapter".to_owned()
    } else {
        trimmed.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supported_formats_case_insensitively() {
        assert_eq!(".M4A".parse::<AudioFormat>(), Ok(AudioFormat::M4a));
        assert_eq!("mp3".parse::<AudioFormat>(), Ok(AudioFormat::Mp3));
    }

    #[test]
    fn rejects_unknown_formats_and_engines() {
        assert!("wav".parse::<AudioFormat>().is_err());
        assert!("coqui".parse::<Engine>().is_err());
    }

    #[test]
    fn builds_safe_output_filename() {
        let chapter = Chapter {
            index: "1.2".to_owned(),
            title: "A/B: C?".to_owned(),
            text: "text".to_owned(),
        };
        assert_eq!(
            chapter.output_filename(AudioFormat::M4a),
            "1.2 - A_B_ C_.m4a"
        );
    }

    #[test]
    fn tracks_job_progress_and_rejects_invalid_transitions() {
        let mut job = ConversionJob::new("job-1", 2);
        assert_eq!(job.snapshot().state, JobState::Queued);
        assert!(job.finish().is_err());
        job.start().unwrap();
        job.complete_chapter().unwrap();
        assert_eq!(job.snapshot().chapters_completed, 1);
        assert!(job.finish().is_err());
        job.complete_chapter().unwrap();
        job.finish().unwrap();
        assert_eq!(job.snapshot().state, JobState::Finished);
        assert!(job.cancel().is_err());
    }

    #[test]
    fn records_failure_and_error_message() {
        let mut job = ConversionJob::new("job-2", 1);
        job.start().unwrap();
        job.fail("engine unavailable").unwrap();
        let snapshot = job.snapshot();
        assert_eq!(snapshot.state, JobState::Failed);
        assert_eq!(snapshot.error.as_deref(), Some("engine unavailable"));
    }

    #[test]
    fn builds_a_conversion_plan_with_safe_outputs() {
        let book = BookStructure {
            title: "Book".to_owned(),
            author: Some("Author".to_owned()),
            chapters: vec![Chapter {
                index: "1".to_owned(),
                title: "Opening".to_owned(),
                text: "Narratable text".to_owned(),
            }],
        };
        let plan = ConversionPlan::from_book(&book, ConversionOptions::default()).unwrap();
        assert_eq!(plan.chapters[0].output_filename, "1 - Opening.mp3");
        assert_eq!(plan.chapters[0].text, "Narratable text");
    }

    #[test]
    fn detects_narratable_structure() {
        let empty = BookStructure {
            title: "Book".to_owned(),
            author: None,
            chapters: vec![],
        };
        assert!(!empty.is_narratable());
    }
}
