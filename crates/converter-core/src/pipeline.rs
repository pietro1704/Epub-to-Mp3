use std::fs;
use std::path::{Path, PathBuf};

use crate::audio::{AudioArtifact, AudioBackend, AudioError, AudioRequest};
use crate::{
    BookStructure, ConversionJob, ConversionOptions, ConversionPlan, DomainError, JobSnapshot,
};

#[derive(Debug)]
pub enum PipelineError {
    InvalidBook,
    Io(std::io::Error),
    Audio(AudioError),
    EmptyOutput {
        chapter_index: String,
        path: PathBuf,
    },
    InvalidJobTransition(DomainError),
}

impl std::fmt::Display for PipelineError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidBook => formatter.write_str("book has no narratable chapters"),
            Self::Io(error) => write!(formatter, "pipeline I/O failed: {error}"),
            Self::Audio(error) => write!(formatter, "audio backend failed: {error}"),
            Self::EmptyOutput {
                chapter_index,
                path,
            } => {
                write!(
                    formatter,
                    "chapter {chapter_index} produced empty output: {}",
                    path.display()
                )
            }
            Self::InvalidJobTransition(error) => {
                write!(formatter, "job transition failed: {error}")
            }
        }
    }
}

impl std::error::Error for PipelineError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversionResult {
    pub snapshot: JobSnapshot,
    pub outputs: Vec<PathBuf>,
}

#[derive(Debug)]
pub struct ConversionPipeline<B> {
    backend: B,
}

impl<B: AudioBackend> ConversionPipeline<B> {
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    pub fn convert_book(
        &self,
        job_id: impl Into<String>,
        book: &BookStructure,
        output_dir: &Path,
        options: ConversionOptions,
    ) -> Result<ConversionResult, PipelineError> {
        let plan =
            ConversionPlan::from_book(book, options).map_err(|_| PipelineError::InvalidBook)?;
        fs::create_dir_all(output_dir).map_err(PipelineError::Io)?;
        let mut job = ConversionJob::new(job_id, plan.chapters.len());
        job.start().map_err(PipelineError::InvalidJobTransition)?;
        let mut outputs = Vec::with_capacity(plan.chapters.len());
        for chapter in plan.chapters {
            let request = AudioRequest::new(chapter.clone(), output_dir);
            let artifact = match self.backend.synthesize(&request) {
                Ok(artifact) => artifact,
                Err(error) => {
                    let _ = job.fail(error.to_string());
                    return Err(PipelineError::Audio(error));
                }
            };
            if let Err(error) = validate_artifact(&chapter.index, &artifact) {
                let _ = job.fail(error.to_string());
                return Err(error);
            }
            outputs.push(artifact.path);
            job.complete_chapter()
                .map_err(PipelineError::InvalidJobTransition)?;
        }
        job.finish().map_err(PipelineError::InvalidJobTransition)?;
        Ok(ConversionResult {
            snapshot: job.snapshot(),
            outputs,
        })
    }
}

fn validate_artifact(chapter_index: &str, artifact: &AudioArtifact) -> Result<(), PipelineError> {
    let metadata = fs::metadata(&artifact.path).map_err(PipelineError::Io)?;
    if metadata.len() == 0 {
        return Err(PipelineError::EmptyOutput {
            chapter_index: chapter_index.to_owned(),
            path: artifact.path.clone(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AudioFormat, Chapter};
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct FakeBackend {
        calls: Arc<Mutex<Vec<String>>>,
    }

    impl AudioBackend for FakeBackend {
        fn synthesize(&self, request: &AudioRequest) -> Result<AudioArtifact, AudioError> {
            self.calls
                .lock()
                .unwrap()
                .push(request.chapter.index.clone());
            fs::write(&request.output, request.chapter.text.as_bytes())
                .map_err(|error| AudioError::SynthesisFailed(error.to_string()))?;
            Ok(AudioArtifact {
                path: request.output.clone(),
                format: AudioFormat::Mp3,
                duration_millis: 1,
            })
        }
    }

    fn book() -> BookStructure {
        BookStructure {
            title: "Book".to_owned(),
            author: None,
            chapters: vec![
                Chapter {
                    index: "1".to_owned(),
                    title: "One".to_owned(),
                    text: "one".to_owned(),
                },
                Chapter {
                    index: "2".to_owned(),
                    title: "Two".to_owned(),
                    text: "two".to_owned(),
                },
            ],
        }
    }

    #[test]
    fn converts_chapters_in_spine_order_and_finishes_job() {
        let root = std::env::temp_dir().join(format!("epub2mp3-pipeline-{}", std::process::id()));
        let backend = FakeBackend::default();
        let calls = backend.calls.clone();
        let result = ConversionPipeline::new(backend)
            .convert_book("job", &book(), &root, ConversionOptions::default())
            .unwrap();
        assert_eq!(result.snapshot.state, crate::JobState::Finished);
        assert_eq!(*calls.lock().unwrap(), ["1", "2"]);
        assert_eq!(result.outputs.len(), 2);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_empty_book_before_creating_outputs() {
        let empty = BookStructure {
            title: "Empty".to_owned(),
            author: None,
            chapters: vec![],
        };
        let result = ConversionPipeline::new(FakeBackend::default()).convert_book(
            "job",
            &empty,
            Path::new("/tmp/unused"),
            ConversionOptions::default(),
        );
        assert!(matches!(result, Err(PipelineError::InvalidBook)));
    }
}
