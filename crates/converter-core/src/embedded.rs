//! API for embedding the conversion core directly into application clients.

use crate::{
    config::AppConfig,
    epub::Book,
    jobs::JobError,
    structure::StructureVerification,
    worker::{ConversionRequest, ConversionWorker, ExecutionOptions, OutputManifest, WorkerError},
};
use std::path::{Path, PathBuf};
use thiserror::Error;

/// Explicit options for an embedded conversion.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EmbeddedConversionOptions {
    pub job_id: Option<String>,
    pub tts_preferences: Option<crate::tts_preferences::TtsPreferences>,
    pub models_root: Option<PathBuf>,
    pub piper_model: Option<PathBuf>,
    pub piper_config: Option<PathBuf>,
    pub engine: Option<String>,
    pub voice: Option<String>,
    pub language: Option<String>,
    pub chapter_indices: Option<Vec<String>>,
    pub no_parallel: bool,
    /// Per-invocation cache controls. The default reuses validated audio.
    pub execution_options: ExecutionOptions,
}

/// Allocate a path-safe identity for a fresh conversion without a caller-owned ID.
pub fn fresh_embedded_job_id() -> String {
    format!(
        "embedded-{}-{:032x}",
        std::process::id(),
        rand::random::<u128>()
    )
}

/// Parsed EPUB/PDF metadata exposed before audio conversion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddedBookMetadata {
    pub title: String,
    pub author: String,
    pub language: Option<String>,
    pub chapters: Vec<EmbeddedChapterMetadata>,
    /// The book's own contents list (nav/NCX); empty when the book has none.
    pub toc: Vec<EmbeddedTocEntry>,
    /// Source pages without selectable text, left out of narration (PDF only).
    pub skipped_pages: usize,
}

/// One contents entry with the 1-based position of the chapter it opens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddedTocEntry {
    pub title: String,
    pub level: u32,
    pub chapter_index: Option<usize>,
    /// The `#fragment` the entry points at inside that chapter's file, decoded; clients jump to
    /// the matching anchor offset of the reader chapter.
    pub fragment: Option<String>,
    pub children: Vec<EmbeddedTocEntry>,
}

fn toc_entries(
    items: &[crate::toc::TocItem],
    chapters: &[crate::epub::Chapter],
) -> Vec<EmbeddedTocEntry> {
    items
        .iter()
        .map(|item| {
            let file = item.href.split('#').next().unwrap_or_default();
            let chapter_index = (!file.is_empty())
                .then(|| {
                    chapters.iter().position(|chapter| {
                        chapter.source_path == file
                            || chapter.source_path.ends_with(&format!("/{file}"))
                    })
                })
                .flatten()
                .map(|position| position + 1);
            EmbeddedTocEntry {
                title: item.title.clone(),
                level: item.level,
                chapter_index,
                fragment: item
                    .href
                    .split_once('#')
                    .map(|(_, fragment)| {
                        percent_encoding::percent_decode_str(fragment)
                            .decode_utf8_lossy()
                            .into_owned()
                    })
                    .filter(|fragment| !fragment.is_empty()),
                children: toc_entries(&item.children, chapters),
            }
        })
        .collect()
}

/// Metadata for one parsed chapter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddedChapterMetadata {
    pub index: String,
    pub name: String,
    pub source_path: String,
    pub text_chars: usize,
    pub text: String,
    pub level: u32,
    /// Plain-text footnote bodies linked from this chapter; empty when none.
    pub footnotes: Vec<crate::epub::Footnote>,
    /// TOC fragment ids with their scalar offset inside `text`; empty when none.
    pub anchors: Vec<(String, usize)>,
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
        source: crate::book_input::BookInputError,
    },
    #[error(transparent)]
    Conversion(#[from] WorkerError),
}

impl EmbeddedConversionError {
    /// The message followed by the additive `[[error_code_v1]]` marker when the
    /// failure has a stable code; a missing input file keeps its plain message.
    pub fn message_with_code(&self) -> String {
        match self {
            Self::ReadInput { .. } => self.to_string(),
            Self::ParseInput { source, .. } => {
                use crate::worker::{ERROR_CODE_CLOSE, ERROR_CODE_OPEN};
                let code = crate::worker::book_input_code(source);
                format!("{self} {ERROR_CODE_OPEN}{code}{ERROR_CODE_CLOSE}")
            }
            Self::Conversion(error) => error.message_with_code(),
        }
    }
}

/// A local-file conversion session independent of HTTP or server types.
#[derive(Debug, Clone)]
pub struct EmbeddedConversionSession {
    input: PathBuf,
    expected_source_sha256: Option<String>,
    options: EmbeddedConversionOptions,
    metadata: EmbeddedBookMetadata,
    structure: StructureVerification,
    config: AppConfig,
}

impl EmbeddedConversionSession {
    /// Parse a local EPUB or text-layer PDF and prepare a conversion session.
    pub fn open<P: AsRef<Path>>(
        input: P,
        options: EmbeddedConversionOptions,
        config: AppConfig,
    ) -> Result<Self, EmbeddedConversionError> {
        let input = input.as_ref().to_path_buf();
        let file =
            std::fs::File::open(&input).map_err(|source| EmbeddedConversionError::ReadInput {
                path: input.clone(),
                source,
            })?;
        let book = crate::book_input::parse_book_reader(&input, std::io::BufReader::new(file))
            .map_err(|source| EmbeddedConversionError::ParseInput {
                path: input.clone(),
                source,
            })?;
        let structure = crate::book_input::verify_book_source(&input, &book);
        Ok(Self {
            input,
            expected_source_sha256: None,
            options,
            metadata: metadata_from_book(&book),
            structure,
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

    /// Return TOC/source-structure verification for every client adapter.
    pub fn structure_verification(&self) -> &StructureVerification {
        &self.structure
    }

    /// Reopen the request a previous job persisted, so that job can be retried or
    /// repaired in place with exactly the selection that produced its output.
    /// `input` replaces the recorded source path, which may have been relative
    /// to another working directory; audio identity depends on source content.
    pub fn reopen_job<P: AsRef<Path>>(
        job_id: &str,
        input: P,
        config: AppConfig,
    ) -> Result<Self, EmbeddedConversionError> {
        if job_id.is_empty() || matches!(job_id, "." | "..") || job_id.contains(['/', '\\', '\0']) {
            return Err(WorkerError::Job(JobError::InvalidJobId).into());
        }
        let request: ConversionRequest = crate::cache::read_json(
            crate::worker::persisted_request_path(&config.paths.jobs_dir, job_id),
        )
        .map_err(WorkerError::from)?;
        if request.job_id != job_id {
            return Err(WorkerError::Job(JobError::InvalidJobId).into());
        }
        let expected_source_sha256 = crate::cache::read_json::<OutputManifest>(
            config.paths.output_dir.join(job_id).join("manifest.json"),
        )
        .ok()
        .and_then(|manifest| manifest.source_sha256);
        let mut session = Self::open(
            input,
            EmbeddedConversionOptions {
                job_id: Some(request.job_id),
                tts_preferences: request.tts_preferences,
                models_root: request.models_root,
                piper_model: request.piper_model,
                piper_config: request.piper_config,
                engine: request.engine,
                voice: request.voice,
                language: request.language,
                chapter_indices: request.chapter_indices,
                no_parallel: request.no_parallel,
                execution_options: ExecutionOptions::default(),
            },
            config,
        )?;
        session.expected_source_sha256 = expected_source_sha256;
        Ok(session)
    }

    /// Run conversion synchronously using the embedded worker.
    pub fn convert(&self) -> Result<OutputManifest, EmbeddedConversionError> {
        let job_id = self
            .options
            .job_id
            .clone()
            .unwrap_or_else(fresh_embedded_job_id);
        Ok(self.worker()?.run(self.request(job_id))?)
    }

    /// Run this session's job again after a failed or cancelled attempt. Chapters
    /// whose completion receipt still validates are reused; the rest are
    /// synthesized. Requires a caller-owned job ID, and fails for a completed job.
    pub fn retry_failed(&self) -> Result<OutputManifest, EmbeddedConversionError> {
        let job_id = self.caller_job_id()?;
        Ok(self.worker()?.resume(self.request(job_id))?)
    }

    /// Re-run a finished job in place. Every chapter whose completion receipt
    /// still validates for this request is kept; missing, altered or withdrawn
    /// chapters are synthesized again, then the manifest and archive are
    /// republished. A job recorded as still active is never touched.
    pub fn repair(&self) -> Result<OutputManifest, EmbeddedConversionError> {
        self.repair_chapters(&[])
    }

    /// Invalidate receipts for the named source chapter positions, then repair
    /// this job under exclusive ownership. Refused jobs retain every receipt.
    pub fn repair_chapters(
        &self,
        source_indices: &[usize],
    ) -> Result<OutputManifest, EmbeddedConversionError> {
        let job_id = self.caller_job_id()?;
        Ok(self
            .worker()?
            .repair_chapters(self.request(job_id), source_indices)?)
    }

    fn caller_job_id(&self) -> Result<String, EmbeddedConversionError> {
        self.options.job_id.clone().ok_or_else(|| {
            WorkerError::Unsupported("retrying a job requires a caller-owned job ID".into()).into()
        })
    }

    fn worker(&self) -> Result<ConversionWorker, EmbeddedConversionError> {
        let worker = ConversionWorker::new(self.config.clone())?
            .with_execution_options(self.options.execution_options)
            .with_expected_source_sha256(self.expected_source_sha256.clone());
        #[cfg(any(target_os = "linux", target_os = "windows"))]
        let worker = {
            // Adapter presence also affects legacy Edge routing; require an explicit selection.
            let system_requested = self.options.tts_preferences.as_ref().map_or(
                self.options.engine.as_deref() == Some("system"),
                |preferences| {
                    preferences.primary.engine == "system"
                        || preferences
                            .secondary
                            .as_ref()
                            .is_some_and(|secondary| secondary.engine == "system")
                },
            );
            if system_requested {
                worker.with_platform_tts(std::sync::Arc::new(
                    crate::desktop_tts::DesktopPlatformTts::default(),
                ))
            } else {
                worker
            }
        };
        Ok(worker)
    }

    fn request(&self, job_id: String) -> ConversionRequest {
        ConversionRequest {
            input: self.input.clone(),
            job_id,
            tts_preferences: self.options.tts_preferences.clone(),
            models_root: self.options.models_root.clone(),
            engine: self.options.engine.clone(),
            voice: self.options.voice.clone(),
            language: self.options.language.clone(),
            piper_model: self.options.piper_model.clone(),
            piper_config: self.options.piper_config.clone(),
            chapter_indices: self.options.chapter_indices.clone(),
            no_parallel: self.options.no_parallel,
        }
    }
}

fn metadata_from_book(book: &Book) -> EmbeddedBookMetadata {
    EmbeddedBookMetadata {
        skipped_pages: book.skipped_pages,
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
                text: chapter.text.clone(),
                level: chapter.level,
                footnotes: chapter.footnotes.clone(),
                anchors: chapter.anchors.clone(),
            })
            .collect(),
        toc: toc_entries(&book.toc, &book.chapters),
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
    fn toc_entries_carry_their_fragment_without_changing_the_chapter() {
        let item = |href: &str| crate::toc::TocItem {
            title: "T".into(),
            href: href.into(),
            level: 1,
            children: Vec::new(),
        };
        let chapter = crate::epub::Chapter {
            index: "1".into(),
            name: "C".into(),
            source_path: "OPS/c.xhtml".into(),
            text: String::new(),
            paragraph_ends: Vec::new(),
            heading_ends: Vec::new(),
            level: 1,
            footnotes: Vec::new(),
            note_marks: Vec::new(),
            anchors: Vec::new(),
        };
        let entries = toc_entries(
            &[item("c.xhtml"), item("c.xhtml#caf%C3%A9"), item("c.xhtml#")],
            &[chapter],
        );
        let got: Vec<_> = entries
            .iter()
            .map(|e| (e.chapter_index, e.fragment.as_deref()))
            .collect();
        assert_eq!(
            got,
            [(Some(1), None), (Some(1), Some("café")), (Some(1), None)]
        );
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
