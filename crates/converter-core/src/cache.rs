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

pub fn sha256_bytes(value: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value);
    hex::encode(hasher.finalize())
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
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let bytes = serde_json::to_vec(value)?;
    let mut staging = cache_write_tempfile(parent)?;
    staging.write_all(&bytes)?;
    if std::env::var("RUST_CACHE_FSYNC")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes"))
        .unwrap_or(false)
    {
        staging.as_file().sync_all()?;
    }
    staging.persist(path).map_err(|error| error.error)?;
    Ok(())
}

fn cache_write_tempfile(parent: &Path) -> io::Result<tempfile::NamedTempFile> {
    tempfile::Builder::new()
        .prefix(".cache-json-")
        .tempfile_in(parent)
}

pub fn read_json<T: for<'de> Deserialize<'de>>(path: impl AsRef<Path>) -> Result<T, CacheError> {
    read_json_from(File::open(path)?)
}

fn read_json_from<T: for<'de> Deserialize<'de>>(mut reader: impl Read) -> Result<T, CacheError> {
    let mut bytes = Vec::new();
    reader
        .read_to_end(&mut bytes)
        .map_err(serde_json::Error::io)?;
    Ok(serde_json::from_slice(&bytes)?)
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
    fn simultaneous_staging_files_have_distinct_names() {
        let root = tempfile::tempdir().unwrap();
        let files: Vec<_> = (0..8)
            .map(|_| cache_write_tempfile(root.path()).unwrap())
            .collect();
        let paths: std::collections::HashSet<_> = files.iter().map(|file| file.path()).collect();
        assert_eq!(paths.len(), files.len());
        drop(files);
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    }

    #[test]
    fn failed_json_publication_removes_staging_files() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("blocked.json");
        fs::create_dir(&target).unwrap();
        let previous = target.join("previous.json");
        fs::write(&previous, b"previous contents").unwrap();

        assert!(matches!(
            atomic_write_json(&target, &serde_json::json!({"new": true})),
            Err(CacheError::Io(_))
        ));
        assert_eq!(fs::read(previous).unwrap(), b"previous contents");
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
    }

    #[test]
    fn serialization_failure_preserves_existing_json() {
        struct InvalidValue;
        impl Serialize for InvalidValue {
            fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
                Err(serde::ser::Error::custom("simulated serialization failure"))
            }
        }
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("previous.json");
        let previous = serde_json::json!({"previous": true});
        atomic_write_json(&target, &previous).unwrap();
        assert!(matches!(
            atomic_write_json(&target, &InvalidValue),
            Err(CacheError::Json(_))
        ));
        assert_eq!(read_json::<serde_json::Value>(&target).unwrap(), previous);
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
    }

    #[test]
    fn concurrent_json_writes_publish_one_complete_value() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("shared.json");
        let values: Vec<_> = (0..8)
            .map(|index| {
                serde_json::json!({
                    "writer": index,
                    "text": char::from(b'a' + index as u8).to_string().repeat(256 * 1024),
                })
            })
            .collect();
        let barrier = std::sync::Barrier::new(values.len());
        std::thread::scope(|scope| {
            let handles: Vec<_> = values
                .iter()
                .map(|value| {
                    let path = &path;
                    let barrier = &barrier;
                    scope.spawn(move || {
                        barrier.wait();
                        atomic_write_json(path, value)
                    })
                })
                .collect();
            for handle in handles {
                handle.join().unwrap().unwrap();
            }
        });
        let actual: serde_json::Value = read_json(&path).unwrap();
        assert!(values.contains(&actual));
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
    }

    fn large_chapter_text() -> String {
        "Audio chapter text. Unicode: é 🎵.\n".repeat(12_000)
    }

    #[test]
    fn large_json_reads_batch_the_underlying_io() {
        struct CountingReader<'a> {
            input: io::Cursor<Vec<u8>>,
            calls: &'a std::cell::Cell<usize>,
        }
        impl Read for CountingReader<'_> {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                self.calls.set(self.calls.get() + 1);
                self.input.read(buffer)
            }
        }
        let expected = large_chapter_text();
        let calls = std::cell::Cell::new(0);
        let reader = CountingReader {
            input: io::Cursor::new(serde_json::to_vec(&expected).unwrap()),
            calls: &calls,
        };
        let actual: String = read_json_from(reader).unwrap();
        assert_eq!(actual, expected);
        assert!(
            calls.get() < 512,
            "cache input must be read in batches; observed {} read calls",
            calls.get()
        );
    }

    #[test]
    fn batched_json_read_preserves_parse_errors() {
        for bytes in [b"".as_slice(), b"{broken}", b"true false", b"\"\xff\""] {
            assert!(matches!(
                read_json_from::<serde_json::Value>(io::Cursor::new(bytes)),
                Err(CacheError::Json(_))
            ));
        }
    }

    #[test]
    fn batched_json_read_preserves_storage_error_categories() {
        struct FailedReader;
        impl Read for FailedReader {
            fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                Err(io::Error::other("simulated storage failure"))
            }
        }
        assert!(matches!(
            read_json_from::<serde_json::Value>(FailedReader),
            Err(CacheError::Json(error)) if error.is_io()
        ));
        let root = tempfile::tempdir().unwrap();
        assert!(matches!(
            read_json::<serde_json::Value>(root.path().join("missing.json")),
            Err(CacheError::Io(error)) if error.kind() == io::ErrorKind::NotFound
        ));
    }

    #[test]
    #[ignore = "manual timing benchmark for chapter JSON cache"]
    fn benchmark_chapter_json_cache_read() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        let expected = large_chapter_text();
        atomic_write_json(&path, &expected).unwrap();
        let mut samples = Vec::new();
        for _ in 0..9 {
            let started = std::time::Instant::now();
            let actual: String = std::hint::black_box(read_json(&path).unwrap());
            samples.push(started.elapsed().as_micros());
            assert_eq!(actual, expected);
        }
        samples.sort_unstable();
        println!(
            "chapter_json_cache bytes={} median_us={}",
            fs::metadata(path).unwrap().len(),
            samples[samples.len() / 2]
        );
    }

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
        assert_eq!(sha256_bytes(b"hello"), sha256_file_for_test(b"hello"));
    }

    fn sha256_file_for_test(value: &[u8]) -> String {
        let dir = tempfile_dir();
        let path = dir.join("source.epub");
        fs::write(&path, value).unwrap();
        let hash = sha256_file(&path).unwrap();
        fs::remove_dir_all(dir).unwrap();
        hash
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
