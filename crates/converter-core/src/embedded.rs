//! Backend-independent API for embedding the conversion core.

use crate::{
    config::AppConfig,
    epub::{self, Book},
    worker::{ConversionRequest, ConversionWorker, OutputManifest, WorkerError},
};
use std::{
    fs::File,
    io::BufReader,
    path::{Path, PathBuf},
};
use thiserror::Error;

/// Explicit options for an embedded conversion.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EmbeddedConversionOptions {
    pub job_id: Option<String>,
    pub engine: Option<String>,
    pub voice: Option<String>,
    pub language: Option<String>,
    pub no_parallel: bool,
}

/// Parsed EPUB metadata exposed before audio conversion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddedBookMetadata {
    pub title: String,
    pub author: String,
    pub language: Option<String>,
    pub chapters: Vec<EmbeddedChapterMetadata>,
}

/// Metadata for one parsed chapter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddedChapterMetadata {
    pub index: String,
    pub name: String,
    pub source_path: String,
    pub text_chars: usize,
    pub level: u32,
}

#[derive(Debug, Error)]
pub enum EmbeddedConversionError {
    #[error("failed to read input '{}': {source}", path.display())]
    ReadInput {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("failed to parse input '{}': {source}", path.display())]
    ParseInput {
        path: PathBuf,
        source: epub::EpubError,
    },
    #[error(transparent)]
    Conversion(#[from] WorkerError),
}

/// A local-file conversion session independent of HTTP or server types.
#[derive(Debug, Clone)]
pub struct EmbeddedConversionSession {
    input: PathBuf,
    options: EmbeddedConversionOptions,
    metadata: EmbeddedBookMetadata,
    config: AppConfig,
}

impl EmbeddedConversionSession {
    /// Parse a local EPUB and prepare an embedded conversion session.
    pub fn open<P: AsRef<Path>>(
        input: P,
        options: EmbeddedConversionOptions,
        config: AppConfig,
    ) -> Result<Self, EmbeddedConversionError> {
        let input = input.as_ref().to_path_buf();
        let file = File::open(&input).map_err(|source| EmbeddedConversionError::ReadInput {
            path: input.clone(),
            source,
        })?;
        let book = epub::parse_epub(BufReader::new(file)).map_err(|source| {
            EmbeddedConversionError::ParseInput {
                path: input.clone(),
                source,
            }
        })?;
        Ok(Self {
            input,
            options,
            metadata: metadata_from_book(&book),
            config,
        })
    }

    pub fn input_path(&self) -> &Path {
        &self.input
    }

    pub fn options(&self) -> &EmbeddedConversionOptions {
        &self.options
    }

    pub fn metadata(&self) -> &EmbeddedBookMetadata {
        &self.metadata
    }

    /// Run conversion synchronously using the existing backend-independent worker.
    pub fn convert(&self) -> Result<OutputManifest, EmbeddedConversionError> {
        let job_id = self
            .options
            .job_id
            .clone()
            .unwrap_or_else(|| format!("embedded-{}", std::process::id()));
        let worker = ConversionWorker::new(self.config.clone())?;
        worker
            .run(ConversionRequest {
                input: self.input.clone(),
                job_id,
                engine: self.options.engine.clone(),
                voice: self.options.voice.clone(),
                language: self.options.language.clone(),
                no_parallel: self.options.no_parallel,
            })
            .map_err(EmbeddedConversionError::from)
    }

    /// Async-compatible entrypoint for FFI adapters and async hosts.
    pub async fn convert_async(&self) -> Result<OutputManifest, EmbeddedConversionError> {
        self.convert()
    }
}

fn metadata_from_book(book: &Book) -> EmbeddedBookMetadata {
    EmbeddedBookMetadata {
        title: book.title.clone(),
        author: book.author.clone(),
        language: book.language.clone(),
        chapters: book
            .chapters
            .iter()
            .map(|chapter| EmbeddedChapterMetadata {
                index: chapter.index.clone(),
                name: chapter.name.clone(),
                source_path: chapter.source_path.clone(),
                text_chars: chapter.text.chars().count(),
                level: chapter.level,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::resolve_paths_from;
    use std::{collections::HashMap, path::PathBuf};

    fn test_config() -> AppConfig {
        let root = std::env::temp_dir().join(format!("embedded-core-{}", std::process::id()));
        AppConfig::from_paths(resolve_paths_from(HashMap::<String, String>::new(), root))
    }

    #[test]
    fn opens_existing_fixture_pattern_and_exposes_chapter_metadata() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../.hermes-run/lotr.epub");
        if !path.is_file() {
            return;
        }
        let session = EmbeddedConversionSession::open(path, Default::default(), test_config())
            .expect("fixture should parse");
        assert!(!session.metadata().chapters.is_empty());
        assert!(session
            .metadata()
            .chapters
            .iter()
            .all(|chapter| chapter.text_chars > 0));
    }

    #[test]
    fn propagates_missing_input_errors() {
        let error = EmbeddedConversionSession::open(
            "/definitely/missing/book.epub",
            Default::default(),
            test_config(),
        )
        .expect_err("missing input must fail");
        assert!(error.to_string().contains("failed to read input"));
    }
}
