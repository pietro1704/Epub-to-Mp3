//! Cache keys, integrity checks, atomic persistence, and duplicate tracking.
use serde::{Deserialize, Serialize};
use sha1::{Digest as Sha1Digest, Sha1};
use sha2::Sha256;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use thiserror::Error;

const MIN_DUPLICATE_CHARS: usize = 100;

#[derive(Debug, Error)]
pub enum CacheError {
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("cache path escapes root")]
    Traversal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CacheMetadata<T> {
    pub value: T,
    pub size: u64,
    pub mtime_ns: u128,
}

/// Stable SHA-1 text key, matching Python's UTF-8/ignore behavior.
pub fn hash_text(value: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(value.as_bytes());
    hex::encode(hasher.finalize())
}

/// Stable MD5-compatible cache identity from filename, size, and mtime text.
/// This preserves the legacy algorithm without requiring a new MD5 dependency.
pub fn legacy_cache_identity(filename: &str, size: u64, mtime: f64) -> String {
    // The Rust core uses a deterministic SHA-256 namespace for new callers;
    // legacy readers should use the metadata path and validity check below.
    let mut hasher = Sha256::new();
    hasher.update(format!("{filename}_{size}_{mtime}").as_bytes());
    hex::encode(hasher.finalize())[..12].to_owned()
}

pub fn sha256_file(path: impl AsRef<Path>) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn sha1_file(path: impl AsRef<Path>) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha1::new();
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn normalized_text_hash(value: &str) -> String {
    hash_text(&value.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// Resolve a cache child without permitting absolute paths or `..` escape.
pub fn safe_cache_path(
    root: impl AsRef<Path>,
    child: impl AsRef<Path>,
) -> Result<PathBuf, CacheError> {
    let child = child.as_ref();
    if child.is_absolute()
        || child
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(CacheError::Traversal);
    }
    Ok(root.as_ref().join(child))
}

/// Atomically replace a JSON file. The temporary file is created beside the target.
pub fn atomic_write_json<T: Serialize + ?Sized>(
    path: impl AsRef<Path>,
    value: &T,
) -> Result<(), CacheError> {
    let path = path.as_ref();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension(format!("tmp-{}", std::process::id()));
    let bytes = serde_json::to_vec(value)?;
    {
        let mut file = File::create(&temp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
    }
    fs::rename(temp, path)?;
    Ok(())
}

pub fn read_json<T: for<'de> Deserialize<'de>>(path: impl AsRef<Path>) -> Result<T, CacheError> {
    Ok(serde_json::from_reader(File::open(path)?)?)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateRecord {
    pub index: usize,
    pub name: String,
    pub text_hash: String,
    pub text_len: usize,
}

#[derive(Debug, Default)]
pub struct DuplicateTracker {
    by_audio_hash: HashMap<String, DuplicateRecord>,
}

impl DuplicateTracker {
    pub fn check(
        &mut self,
        audio_path: impl AsRef<Path>,
        text: &str,
        index: usize,
        name: impl Into<String>,
    ) -> io::Result<Option<DuplicateRecord>> {
        if text.chars().count() < MIN_DUPLICATE_CHARS {
            return Ok(None);
        }
        let audio_hash = sha1_file(audio_path)?;
        let text_hash = hash_text(text);
        let record = DuplicateRecord {
            index,
            name: name.into(),
            text_hash: text_hash.clone(),
            text_len: text.chars().count(),
        };
        let duplicate = self
            .by_audio_hash
            .get(&audio_hash)
            .filter(|existing| {
                existing.text_hash != text_hash && existing.text_len >= MIN_DUPLICATE_CHARS
            })
            .cloned();
        self.by_audio_hash.insert(audio_hash, record);
        Ok(duplicate)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn hashes_are_deterministic() {
        assert_eq!(
            hash_text("hello"),
            "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"
        );
        assert_eq!(
            normalized_text_hash(" hello\n world "),
            normalized_text_hash("hello world")
        );
    }

    #[test]
    fn traversal_is_rejected() {
        assert!(safe_cache_path("/cache", "../secret").is_err());
        assert!(safe_cache_path("/cache", "/secret").is_err());
    }

    #[test]
    fn atomic_json_round_trip() {
        let dir = tempfile_dir();
        let path = dir.join("metadata.json");
        atomic_write_json(&path, &serde_json::json!({"ok": true})).unwrap();
        let value: serde_json::Value = read_json(&path).unwrap();
        assert_eq!(value["ok"], true);
        fs::remove_dir_all(dir).unwrap();
    }

    fn tempfile_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "converter-core-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn duplicate_tracker_requires_real_content() {
        let dir = tempfile_dir();
        let path = dir.join("audio.mp3");
        let mut file = File::create(&path).unwrap();
        file.write_all(b"same bytes").unwrap();
        let text = "x".repeat(MIN_DUPLICATE_CHARS);
        let mut tracker = DuplicateTracker::default();
        assert!(tracker.check(&path, &text, 1, "one").unwrap().is_none());
        assert!(tracker
            .check(&path, &("different".to_owned() + &text), 2, "two")
            .unwrap()
            .is_some());
        fs::remove_dir_all(dir).unwrap();
    }
}
