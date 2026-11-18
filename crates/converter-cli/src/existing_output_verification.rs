//! `--verify-only` and `--fix`: audit the newest retained output of a book.
//!
//! Each conversion owns one job directory under the output root. The audit
//! compares that directory's manifest with the book as it parses today, checks
//! every chapter against the completion receipt the core wrote for it, and
//! decodes the audio. `--fix` then replays the job's persisted request in place:
//! the core keeps every chapter whose receipt still validates and synthesizes
//! only the rest.
use super::conversion_retry::{run_with_retry_rounds, RetryRounds};
use super::output_reporting::{manifest_issues, IssueScope, OutputIssue};
use super::CliOptions;
use converter_core::config::AppConfig;
use converter_core::embedded::{EmbeddedBookMetadata, EmbeddedConversionSession};
use converter_core::worker::OutputManifest;
use std::fs;
use std::path::{Path, PathBuf};

struct RetainedOutput {
    directory: PathBuf,
    manifest: OutputManifest,
}

pub(super) fn verify_existing_outputs(
    inputs: &[String],
    config: &AppConfig,
    options: &CliOptions,
) -> Result<i32, String> {
    let mut exit_code = 0;
    for input in inputs {
        println!("Verify: {input}");
        let session = EmbeddedConversionSession::open(input, Default::default(), config.clone())
            .map_err(|error| error.to_string())?;
        let metadata = session.metadata();
        let source_sha256 = converter_core::cache::sha256_file(input)
            .map_err(|error| format!("cannot identify source '{input}': {error}"))?;
        let Some(retained) = newest_output(&config.paths.output_dir, metadata, &source_sha256)
        else {
            println!(
                "verification failed: no existing output for '{}' under {}; run a conversion first",
                metadata.title,
                config.paths.output_dir.display()
            );
            exit_code = 1;
            continue;
        };
        println!("Output: {}", retained.directory.display());
        let issues = output_issues(&retained, metadata, &source_sha256);
        if issues.is_empty() {
            report_verified(&retained.manifest, metadata);
            continue;
        }
        report_issues(&issues);
        if !options.fix {
            println!(
                "verification failed: {} issue(s) in job {}; run with --fix to reconvert the affected chapters",
                issues.len(),
                retained.manifest.job_id
            );
            exit_code = 1;
            continue;
        }
        if !fix_output(
            input,
            &retained,
            &issues,
            metadata,
            &source_sha256,
            config,
            options,
        )? {
            exit_code = 1;
        }
    }
    Ok(exit_code)
}

/// The newest job directory holding these exact source bytes. A matching source
/// identity is preferred over a newer job with the same descriptive metadata,
/// so an unrelated book with the same title is not audited by mistake.
fn newest_output(
    output_root: &Path,
    metadata: &EmbeddedBookMetadata,
    source_sha256: &str,
) -> Option<RetainedOutput> {
    let mut candidates = Vec::new();
    for entry in fs::read_dir(output_root).ok()?.flatten() {
        let directory = entry.path();
        // A job directory is a plain directory named after its job.
        if !entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let manifest_path = directory.join("manifest.json");
        let Ok(manifest) = converter_core::cache::read_json::<OutputManifest>(&manifest_path)
        else {
            continue;
        };
        if manifest.title != metadata.title
            || entry.file_name().to_str() != Some(manifest.job_id.as_str())
        {
            continue;
        }
        let modified = fs::metadata(&manifest_path)
            .and_then(|metadata| metadata.modified())
            .ok();
        let matches_book = source_issues(&manifest, metadata, source_sha256).is_empty();
        candidates.push((
            matches_book,
            modified,
            RetainedOutput {
                directory,
                manifest,
            },
        ));
    }
    candidates
        .into_iter()
        .max_by(|left, right| {
            (left.0, left.1, &left.2.manifest.job_id).cmp(&(
                right.0,
                right.1,
                &right.2.manifest.job_id,
            ))
        })
        .map(|(_, _, retained)| retained)
}

/// Where the manifest no longer describes the book as it parses today.
fn source_issues(
    manifest: &OutputManifest,
    metadata: &EmbeddedBookMetadata,
    source_sha256: &str,
) -> Vec<OutputIssue> {
    let mut issues = Vec::new();
    if manifest.source_sha256.as_deref() != Some(source_sha256) {
        issues.push(OutputIssue::new(
            IssueScope::Source,
            match &manifest.source_sha256 {
                Some(_) => "output belongs to different source bytes; the book has changed".into(),
                None => {
                    "legacy output has no source identity; it cannot be verified or repaired safely"
                        .into()
                }
            },
        ));
    }
    let source_total = metadata.chapters.len();
    if manifest
        .source_chapters_total
        .is_some_and(|recorded| recorded != source_total)
    {
        issues.push(OutputIssue::new(
            IssueScope::Source,
            format!(
                "output was converted from {} source chapters; the book now has {source_total}",
                manifest.source_chapters_total.unwrap_or_default()
            ),
        ));
    }
    for chapter in &manifest.chapters {
        let Some(source) = metadata.chapters.get(chapter.source_index) else {
            issues.push(OutputIssue::new(
                IssueScope::Source,
                format!(
                    "chapter {} refers to source chapter {}, which the book does not have",
                    chapter.index, chapter.source_index
                ),
            ));
            continue;
        };
        if source.name != chapter.title {
            issues.push(OutputIssue::new(
                IssueScope::Source,
                format!(
                    "chapter {} is '{}' in the output but '{}' in the book",
                    chapter.index, chapter.title, source.name
                ),
            ));
        } else if chapter.text_offset + chapter.text_chars != source.text_chars {
            // Changed text changes the identity of every chapter of the book, so
            // this is not a single chapter that a replay could repair.
            issues.push(OutputIssue::new(
                IssueScope::Source,
                format!(
                    "chapter {} narrates {} characters; the book chapter now has {}",
                    chapter.index,
                    chapter.text_offset + chapter.text_chars,
                    source.text_chars
                ),
            ));
        }
    }
    issues
}

fn output_issues(
    retained: &RetainedOutput,
    metadata: &EmbeddedBookMetadata,
    source_sha256: &str,
) -> Vec<OutputIssue> {
    let manifest = &retained.manifest;
    let unsafe_files: Vec<_> = manifest
        .chapters
        .iter()
        .map(|chapter| chapter.filename.as_str())
        .chain(std::iter::once(manifest.archive.as_str()))
        .chain(manifest.cover.as_deref())
        .filter(|name| {
            Path::new(name).file_name().and_then(|part| part.to_str()) != Some(*name)
                || name.contains('\\')
                || fs::symlink_metadata(retained.directory.join(name))
                    .is_ok_and(|entry| entry.file_type().is_symlink())
        })
        .map(|name| OutputIssue::new(IssueScope::Source, format!("unsafe output path '{name}'")))
        .collect();
    if !unsafe_files.is_empty() {
        return unsafe_files;
    }
    let mut issues = manifest_issues(&retained.directory, manifest);
    issues.extend(source_issues(manifest, metadata, source_sha256));
    for (position, chapter) in manifest.chapters.iter().enumerate() {
        let audio = retained.directory.join(&chapter.filename);
        if !fs::metadata(&audio).is_ok_and(|metadata| metadata.len() > 0) {
            continue; // Already reported as missing or empty.
        }
        if !converter_core::worker::retained_chapter_audio_is_intact(&audio) {
            issues.push(OutputIssue::new(
                IssueScope::Chapter(position),
                format!("{} does not match its completion receipt", audio.display()),
            ));
        } else if let Err(error) = converter_core::audio::validate_audio(&audio, 1) {
            issues.push(OutputIssue::new(
                IssueScope::Chapter(position),
                format!("{} does not decode: {error}", audio.display()),
            ));
        }
    }
    let archive_files: Vec<_> = manifest
        .chapters
        .iter()
        .map(|chapter| {
            (
                retained.directory.join(&chapter.filename),
                chapter.filename.clone(),
            )
        })
        .chain(
            manifest
                .cover
                .iter()
                .map(|name| (retained.directory.join(name), name.clone())),
        )
        .collect();
    if let Err(error) = converter_core::audio::validate_archive(
        &retained.directory.join(&manifest.archive),
        &archive_files,
    ) {
        issues.push(OutputIssue::new(
            IssueScope::Archive,
            format!("archive verification failed: {error}"),
        ));
    }
    issues
}

fn report_issues(issues: &[OutputIssue]) {
    for issue in issues {
        println!("issue: {}", issue.message);
    }
}

fn report_verified(manifest: &OutputManifest, metadata: &EmbeddedBookMetadata) {
    println!(
        "verified: job {}, {} of {} source chapters and archive",
        manifest.job_id,
        manifest.chapters.len(),
        metadata.chapters.len()
    );
}

/// Reconvert the chapters that failed the audit. Returns whether the output is
/// intact afterwards; a conversion failure is an error like any other conversion.
fn fix_output(
    input: &str,
    retained: &RetainedOutput,
    issues: &[OutputIssue],
    metadata: &EmbeddedBookMetadata,
    source_sha256: &str,
    config: &AppConfig,
    options: &CliOptions,
) -> Result<bool, String> {
    let job_id = &retained.manifest.job_id;
    if issues.iter().any(|issue| issue.scope == IssueScope::Source) {
        println!(
            "fix failed: job {job_id} no longer matches the book and cannot be repaired in place; run a new conversion"
        );
        return Ok(false);
    }
    // Reopen before withdrawing any receipt, so an unrepairable job is untouched.
    let session = EmbeddedConversionSession::reopen_job(job_id, input, config.clone())
        .map_err(|error| format!("--fix cannot reopen job {job_id}: {error}"))?;
    let mut chapters: Vec<usize> = issues
        .iter()
        .filter_map(|issue| match issue.scope {
            IssueScope::Chapter(position) => {
                Some(retained.manifest.chapters[position].source_index)
            }
            _ => None,
        })
        .collect();
    chapters.sort_unstable();
    chapters.dedup();
    // The core rejects a changed source before repair and decides reuse against
    // the replayed request. A changed voice model can widen reconversion beyond
    // the chapters that failed this audit.
    println!(
        "fixing job {job_id}: {} chapter(s) failed the audit; replaying the job and reusing every chapter that still validates",
        chapters.len()
    );
    let manifest =
        run_with_retry_rounds(&session, RetryRounds::from_options(options), |session| {
            session.repair_chapters(&chapters)
        })?;
    let repaired = RetainedOutput {
        directory: retained.directory.clone(),
        manifest,
    };
    let remaining = output_issues(&repaired, metadata, source_sha256);
    if remaining.is_empty() {
        report_verified(&repaired.manifest, metadata);
        return Ok(true);
    }
    report_issues(&remaining);
    println!(
        "fix failed: {} issue(s) remain in job {job_id}",
        remaining.len()
    );
    Ok(false)
}
