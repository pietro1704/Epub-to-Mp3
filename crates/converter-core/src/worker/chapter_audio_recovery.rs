use super::{
    chapter_audio_receipt::{chapter_audio_is_reusable, chapter_audio_receipt_path},
    WorkerError,
};
use std::{fs, path::Path};

/// Import only a complete, identity-matched chapter from a direct sibling job.
/// The predecessor remains immutable; untrusted or unavailable artifacts simply
/// fall through to normal synthesis without weakening completion receipts.
#[cfg(test)]
pub(super) fn recover_chapter_audio(
    output_root: &Path,
    predecessor: &str,
    output: &Path,
    request_key: &str,
    check_cancelled: &impl Fn() -> Result<(), WorkerError>,
) -> Result<(), WorkerError> {
    recover_chapter_audio_with_native_policy(
        output_root,
        predecessor,
        output,
        request_key,
        false,
        check_cancelled,
    )
}

#[cfg(test)]
pub(super) fn recover_chapter_audio_with_native_policy(
    output_root: &Path,
    predecessor: &str,
    output: &Path,
    request_key: &str,
    reject_opaque_native: bool,
    check_cancelled: &impl Fn() -> Result<(), WorkerError>,
) -> Result<(), WorkerError> {
    recover_chapter_audio_for_generation(
        output_root,
        predecessor,
        output,
        request_key,
        reject_opaque_native,
        check_cancelled,
        None,
        None,
        None,
    )
}

pub(super) fn recover_chapter_audio_for_generation(
    output_root: &Path,
    predecessor: &str,
    output: &Path,
    request_key: &str,
    reject_opaque_native: bool,
    check_cancelled: &impl Fn() -> Result<(), WorkerError>,
    control: Option<&crate::conversion_control::ConversionControl>,
    generation: Option<u64>,
    chapter: Option<usize>,
) -> Result<(), WorkerError> {
    check_cancelled()?;
    if predecessor.is_empty()
        || matches!(predecessor, "." | "..")
        || predecessor.contains(['/', '\\', '\0'])
    {
        return Ok(());
    }
    let source_directory = output_root.join(predecessor);
    let Some(filename) = output.file_name() else {
        return Ok(());
    };
    // Do not follow links into another job or outside the output root.
    let is_plain_directory =
        fs::symlink_metadata(&source_directory).is_ok_and(|metadata| metadata.file_type().is_dir());
    let is_plain_file = |path: &Path| {
        fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file())
    };
    if !is_plain_directory {
        return Ok(());
    }
    let (Ok(root), Ok(directory)) = (
        fs::canonicalize(output_root),
        fs::canonicalize(&source_directory),
    ) else {
        return Ok(());
    };
    if directory.parent() != Some(root.as_path()) {
        return Ok(());
    }
    let is_matching_source = |path: &Path| {
        is_plain_file(path)
            && is_plain_file(&chapter_audio_receipt_path(path))
            && chapter_audio_is_reusable(path, request_key, reject_opaque_native)
    };
    let expected_source = source_directory.join(filename);
    let source = if is_matching_source(&expected_source) {
        expected_source
    } else {
        // Filenames number the current selection, not the source chapter.
        // Completion receipts retain the source identity across selections.
        let Ok(entries) = fs::read_dir(&source_directory) else {
            return Ok(());
        };
        let Some(source) = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| {
                path.extension().is_some_and(|extension| extension == "mp3")
                    && is_matching_source(path)
            })
        else {
            return Ok(());
        };
        source
    };
    let source_receipt = chapter_audio_receipt_path(&source);
    let Some(parent) = output.parent() else {
        return Ok(());
    };
    let staging = tempfile::Builder::new()
        .prefix(".chapter-recovery-")
        .tempdir_in(parent)?;
    let pending = staging.path().join("chapter.mp3");
    let pending_receipt = chapter_audio_receipt_path(&pending);
    if fs::copy(&source, &pending).is_err() || fs::copy(source_receipt, &pending_receipt).is_err() {
        return Ok(());
    }
    // Revalidate the copied pair so a concurrently replaced source cannot
    // publish bytes that disagree with the accepted completion receipt.
    if !chapter_audio_is_reusable(&pending, request_key, reject_opaque_native) {
        return Ok(());
    }
    let _lease = match control
        .map(|control| control.lease_generation(generation, chapter))
        .transpose()
    {
        Ok(lease) => lease,
        Err(_) => return Ok(()),
    };
    check_cancelled()?;
    fs::rename(pending, output)?;
    fs::rename(pending_receipt, chapter_audio_receipt_path(output))?;
    Ok(())
}
