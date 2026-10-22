use super::WorkerError;
use crate::{audio, cache};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub(super) fn cached_chapter_text(path: &Path, expected: &str) -> Result<String, WorkerError> {
    if let Ok(text) = cache::read_json::<String>(path) {
        if text == expected {
            return Ok(text);
        }
    }
    cache::atomic_write_json(path, expected)?;
    Ok(expected.to_owned())
}

pub(super) fn chapter_audio_request_key(
    source_key: &str,
    chapter_index: &str,
    text: &str,
    engine: &str,
    voice: Option<&str>,
    language: Option<&str>,
) -> Result<String, WorkerError> {
    let text_key = cache::sha256_bytes(text.as_bytes());
    let request =
        serde_json::to_vec(&(source_key, chapter_index, text_key, engine, voice, language))
            .map_err(cache::CacheError::from)?;
    Ok(cache::sha256_bytes(&request))
}

#[derive(Debug, Serialize, Deserialize)]
pub(super) struct ChapterAudioReceipt {
    pub(super) version: u8,
    pub(super) fallback_used: bool,
    #[serde(default)]
    pub(super) provider: Option<String>,
    #[serde(default)]
    pub(super) used_selections: Vec<crate::tts_preferences::TtsSelection>,
    pub(super) request_key: String,
    pub(super) audio_sha256: String,
    pub(super) size: u64,
}

pub(super) fn chapter_audio_receipt_path(output: &Path) -> PathBuf {
    output.with_extension("mp3.complete.json")
}

pub(super) fn chapter_audio_is_complete(output: &Path, request_key: &str) -> bool {
    let Ok(receipt) = cache::read_json::<ChapterAudioReceipt>(chapter_audio_receipt_path(output))
    else {
        return false;
    };
    if receipt.version != 2 || receipt.request_key != request_key || receipt.size == 0 {
        return false;
    }
    fs::metadata(output).is_ok_and(|metadata| metadata.is_file() && metadata.len() == receipt.size)
        && cache::sha256_file(output).is_ok_and(|hash| hash == receipt.audio_sha256)
}

/// A requested fallback does not invalidate healthy Piper audio. Unknown native
/// voice identities prevent reuse only when native synthesis actually occurred.
pub(super) fn chapter_audio_is_reusable(
    output: &Path,
    key: &str,
    reject_opaque_native: bool,
) -> bool {
    if !chapter_audio_is_complete(output, key) {
        return false;
    }
    if !reject_opaque_native {
        return true;
    }
    cache::read_json::<ChapterAudioReceipt>(chapter_audio_receipt_path(output)).is_ok_and(
        |receipt| {
            !receipt.used_selections.is_empty()
                && receipt.used_selections.iter().all(|s| s.engine != "system")
                && !receipt
                    .provider
                    .as_deref()
                    .is_some_and(|p| p.contains("system"))
        },
    )
}

pub(super) fn refresh_chapter_audio_receipt(output: &Path) -> Result<(), WorkerError> {
    let receipt_path = chapter_audio_receipt_path(output);
    let mut receipt: ChapterAudioReceipt = cache::read_json(&receipt_path)?;
    receipt.size = fs::metadata(output)?.len();
    receipt.audio_sha256 = cache::sha256_file(output)?;
    cache::atomic_write_json(receipt_path, &receipt)?;
    Ok(())
}

#[cfg(test)]
pub(super) fn ensure_chapter_audio(
    output: &Path,
    request_key: &str,
    synthesize: impl FnOnce(&Path) -> Result<(), WorkerError>,
) -> Result<(), WorkerError> {
    ensure_chapter_audio_with_options(output, request_key, false, synthesize)
}

pub(super) fn ensure_chapter_audio_with_options(
    output: &Path,
    request_key: &str,
    force: bool,
    synthesize: impl FnOnce(&Path) -> Result<(), WorkerError>,
) -> Result<(), WorkerError> {
    if !force && chapter_audio_is_complete(output, request_key) {
        return Ok(());
    }
    let parent = output
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new()
        .prefix(".chapter-audio-")
        .tempdir_in(parent)?;
    let pending = staging.path().join("chapter.mp3");
    synthesize(&pending)?;
    if force {
        audio::validate_audio(&pending, 100)?;
    }
    let metadata = fs::metadata(&pending)?;
    if !metadata.is_file() || metadata.len() == 0 {
        return Err(WorkerError::Audio(audio::AudioError::Validation(
            "synthesis produced an empty audio artifact".into(),
        )));
    }
    let usage_path = pending.with_extension("tts-usage.json");
    let (used_selections, fallback_used) = if usage_path.is_file() {
        cache::read_json::<(Vec<crate::tts_preferences::TtsSelection>, bool)>(&usage_path)?
    } else {
        (Vec::new(), false)
    };
    let receipt = ChapterAudioReceipt {
        used_selections,
        version: 2,
        fallback_used,
        provider: fs::read_to_string(pending.with_extension("provider")).ok(),
        request_key: request_key.to_owned(),
        audio_sha256: cache::sha256_file(&pending)?,
        size: metadata.len(),
    };
    // Only publish a successfully finished synthesis. A synthesis failure leaves
    // the previous artifact and its completion receipt intact.
    let pending_receipt = staging.path().join("complete.json");
    cache::atomic_write_json(&pending_receipt, &receipt)?;
    fs::rename(&pending, output)?;
    fs::rename(pending_receipt, chapter_audio_receipt_path(output))?;
    Ok(())
}
