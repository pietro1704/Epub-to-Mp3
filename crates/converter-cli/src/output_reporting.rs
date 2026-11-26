//! Artifact-manifest checks and source-structure reporting.
use super::cli_environment::cli_config;
use std::fs;
use std::path::Path;

/// What a problem in retained output belongs to, which decides how it is repaired.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum IssueScope {
    /// The manifest disagrees with itself or with the book; not repairable in place.
    Source,
    /// One chapter's audio, by its zero-based position in the manifest.
    Chapter(usize),
    /// The archive, which every conversion run republishes.
    Archive,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct OutputIssue {
    pub(super) scope: IssueScope,
    pub(super) message: String,
}

impl OutputIssue {
    pub(super) fn new(scope: IssueScope, message: String) -> Self {
        Self { scope, message }
    }
}

/// Every way the files of `output_dir` disagree with their own manifest.
pub(super) fn manifest_issues(
    output_dir: &Path,
    manifest: &converter_core::worker::OutputManifest,
) -> Vec<OutputIssue> {
    if manifest.chapters.is_empty() {
        return vec![OutputIssue::new(
            IssueScope::Source,
            "manifest has no chapters".into(),
        )];
    }
    let mut issues = Vec::new();
    for (position, chapter) in manifest.chapters.iter().enumerate() {
        let expected = position + 1;
        if chapter.index != expected {
            issues.push(OutputIssue::new(
                IssueScope::Source,
                format!("expected chapter {expected}, found {}", chapter.index),
            ));
        }
        let path = output_dir.join(&chapter.filename);
        match fs::metadata(&path) {
            Err(error) => issues.push(OutputIssue::new(
                IssueScope::Chapter(position),
                format!("{}: {error}", path.display()),
            )),
            Ok(metadata) if metadata.len() == 0 => issues.push(OutputIssue::new(
                IssueScope::Chapter(position),
                format!("empty audio {}", path.display()),
            )),
            Ok(_) => {}
        }
        let expected_title = chapter.title.trim();
        let normalized_filename = normalized_name(&chapter.filename);
        let normalized_title = normalized_name(expected_title);
        if !normalized_title.is_empty() && !normalized_filename.contains(&normalized_title) {
            issues.push(OutputIssue::new(
                IssueScope::Source,
                format!(
                    "filename '{}' does not contain TOC title '{}'",
                    chapter.filename, chapter.title
                ),
            ));
        }
    }
    let archive = output_dir.join(&manifest.archive);
    match fs::metadata(&archive) {
        Err(error) => issues.push(OutputIssue::new(
            IssueScope::Archive,
            format!("{}: {error}", archive.display()),
        )),
        Ok(metadata) if metadata.len() == 0 => issues.push(OutputIssue::new(
            IssueScope::Archive,
            format!("empty archive {}", archive.display()),
        )),
        Ok(_) => {}
    }
    issues
}

/// `--verify`: the conversion that just finished must match its manifest.
pub(super) fn verify_output(
    output_dir: &Path,
    manifest: &converter_core::worker::OutputManifest,
) -> Result<(), String> {
    match manifest_issues(output_dir, manifest).into_iter().next() {
        Some(issue) => Err(format!("verification failed: {}", issue.message)),
        None => Ok(()),
    }
}

pub(super) fn normalized_name(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// PDF pages without selectable text are left out of narration; say how many.
pub(super) fn report_skipped_pages(count: usize) {
    if count > 0 {
        eprintln!("Warning: skipped {count} PDF page(s) without selectable text.");
    }
}

pub(super) fn show_structure(inputs: &[String]) -> Result<i32, String> {
    let config = cli_config();
    for input in inputs {
        println!("Structure: {input}");
        // EPUB and PDF share the core source dispatch used by conversion.
        let session = converter_core::embedded::EmbeddedConversionSession::open(
            input,
            Default::default(),
            config.clone(),
        )
        .map_err(|error| error.to_string())?;
        let metadata = session.metadata();
        if !metadata.title.is_empty() {
            println!("Title: {}", metadata.title);
        }
        for chapter in &metadata.chapters {
            println!("{} {}", chapter.index, chapter.name);
        }
        report_skipped_pages(metadata.skipped_pages);
    }
    Ok(0)
}
