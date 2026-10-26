//! Immutable content-addressed segments. This cache never owns chapter artifacts.
use crate::{
    cache,
    tts_session::{AudioFormat, ResolvedIdentity, MAX_SEGMENT_BYTES},
};
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

const BUDGET_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
struct Receipt {
    key: String,
    sha256: String,
    bytes: usize,
}

pub(super) fn key(
    book: &str,
    language: &str,
    text: &str,
    identity: &ResolvedIdentity,
) -> Option<String> {
    let source = serde_json::to_string(&(book, language, text)).ok()?;
    let material = crate::tts_session::cache_material(
        &source,
        "speech-segment-v1",
        identity,
        &AudioFormat::Mp3,
    )
    .ok()?;
    Some(cache::sha256_bytes(material.as_bytes()))
}

pub(super) struct SegmentAudioCache {
    root: PathBuf,
}

impl SegmentAudioCache {
    pub fn new(cache_root: &Path) -> Self {
        Self {
            root: cache_root.join("speech-segments-v1"),
        }
    }

    fn safe_root(&self) -> bool {
        fs::symlink_metadata(&self.root).is_ok_and(|metadata| metadata.file_type().is_dir())
            && fs::canonicalize(&self.root).is_ok_and(|path| {
                fs::canonicalize(self.root.parent().unwrap())
                    .is_ok_and(|parent| path.parent() == Some(parent.as_path()))
            })
    }

    fn directory(&self, key: &str) -> Option<PathBuf> {
        (key.len() == 64 && key.bytes().all(|byte| byte.is_ascii_hexdigit()))
            .then(|| self.root.join(key))
    }

    pub fn load(&self, key: &str) -> Option<Vec<u8>> {
        if !self.safe_root() {
            return None;
        }
        let directory = self.directory(key)?;
        if !fs::symlink_metadata(&directory).ok()?.file_type().is_dir() {
            return None;
        }
        let audio = directory.join("audio.mp3");
        let receipt_file = directory.join("receipt.json");
        for (path, limit) in [(&audio, MAX_SEGMENT_BYTES as u64), (&receipt_file, 2048)] {
            let metadata = fs::symlink_metadata(path).ok()?;
            if !metadata.file_type().is_file() || metadata.len() > limit {
                return None;
            }
        }
        let receipt: Receipt = cache::read_json(receipt_file).ok()?;
        let bytes = fs::read(audio).ok()?;
        if receipt.key != key
            || receipt.bytes != bytes.len()
            || receipt.sha256 != cache::sha256_bytes(&bytes)
            || crate::pcm::validate_mp3(&bytes).is_err()
        {
            return None;
        }
        Some(bytes)
    }

    /// Best-effort cache failures never fail a conversion. Publication is called
    /// under the worker's generation lease, after validated synthesis completes.
    pub fn store(&self, key: &str, bytes: &[u8]) -> io::Result<()> {
        if bytes.is_empty()
            || bytes.len() > MAX_SEGMENT_BYTES
            || crate::pcm::validate_mp3(bytes).is_err()
        {
            return Err(io::Error::other("Invalid cached segment"));
        }
        fs::create_dir_all(&self.root)?;
        if !self.safe_root() {
            return Err(io::Error::other("Unsafe segment cache root"));
        }
        let directory = self
            .directory(key)
            .ok_or_else(|| io::Error::other("Invalid segment key"))?;
        if self.load(key).is_some() {
            return Ok(());
        }
        if fs::symlink_metadata(&directory).is_ok_and(|metadata| metadata.file_type().is_dir()) {
            fs::remove_dir_all(&directory)?;
        }
        self.trim(bytes.len() as u64)?;
        let staging = tempfile::Builder::new()
            .prefix(".segment-")
            .tempdir_in(&self.root)?;
        let audio = staging.path().join("audio.mp3");
        fs::write(&audio, bytes)?;
        fs::File::open(audio)?.sync_all()?;
        cache::atomic_write_json(
            staging.path().join("receipt.json"),
            &Receipt {
                key: key.to_owned(),
                sha256: cache::sha256_bytes(bytes),
                bytes: bytes.len(),
            },
        )
        .map_err(|error| io::Error::other(error.to_string()))?;
        fs::rename(staging.path(), directory)
    }

    fn trim(&self, incoming: u64) -> io::Result<()> {
        let mut entries = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().to_string();
            if self.directory(&name).is_none() || !entry.file_type()?.is_dir() {
                continue;
            }
            let audio = entry.path().join("audio.mp3");
            if let Ok(metadata) = fs::symlink_metadata(audio) {
                if metadata.file_type().is_file() {
                    entries.push((metadata.modified().ok(), metadata.len(), entry.path()));
                }
            }
        }
        entries.sort_by_key(|(modified, _, _)| *modified);
        let mut total = entries.iter().map(|(_, bytes, _)| bytes).sum::<u64>() + incoming;
        for (_, bytes, path) in entries {
            if total <= BUDGET_BYTES {
                break;
            }
            fs::remove_dir_all(path)?;
            total = total.saturating_sub(bytes);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persistent_audio_is_validated_and_corruption_is_a_miss() {
        let root = tempfile::tempdir().unwrap();
        let cache = SegmentAudioCache::new(root.path());
        let key = "a".repeat(64);
        let samples: Vec<f32> = (0..8000)
            .map(|index| (index as f32 * 0.1).sin() * 0.2)
            .collect();
        let bytes = crate::tts_session::encode_pcm_f32(&samples, 16000).unwrap();
        cache.store(&key, &bytes).unwrap();
        assert_eq!(SegmentAudioCache::new(root.path()).load(&key), Some(bytes));
        fs::write(
            cache.directory(&key).unwrap().join("audio.mp3"),
            b"corrupted",
        )
        .unwrap();
        assert!(cache.load(&key).is_none());
        assert!(cache.load("../foreign").is_none());
        assert!(cache.store(&key, b"not audio").is_err());
    }
}
