//! Cache keys, integrity checks, atomic persistence, and duplicate tracking.
mod cache_integrity;
mod cache_persistence;

pub use cache_integrity::{
    hash_text, legacy_cache_identity, normalized_text_hash, sha1_file, sha256_bytes, sha256_file,
};
pub(crate) use cache_persistence::refresh_chapter_text;
pub use cache_persistence::{atomic_write_json, read_json, safe_cache_path};

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io;
use std::path::Path;
use thiserror::Error;

#[cfg(test)]
use cache_persistence::{cache_write_tempfile, read_json_from};
#[cfg(test)]
use std::fs::{self, File};
#[cfg(test)]
use std::io::Read;
#[cfg(test)]
use std::path::PathBuf;

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

    #[test]
    fn refreshing_selected_text_preserves_other_chapters_books_models_and_audio() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().join("cache");
        let book_key = "a".repeat(64);
        let other_key = "b".repeat(64);
        fs::create_dir_all(root.join(&book_key)).unwrap();
        fs::create_dir_all(root.join(&other_key)).unwrap();
        fs::write(root.join(&book_key).join("0.json"), b"broken derived text").unwrap();
        let preserved = [
            root.join(&book_key).join("1.json"),
            root.join(&other_key).join("0.json"),
            fixture.path().join("source.epub"),
            fixture.path().join("model.onnx"),
            fixture.path().join("download.mp3"),
        ];
        for path in &preserved {
            fs::write(path, b"preserve").unwrap();
        }
        assert_eq!(
            refresh_chapter_text(&root, &book_key, "0.json", "fresh source text").unwrap(),
            "fresh source text"
        );
        assert_eq!(
            read_json::<String>(root.join(&book_key).join("0.json")).unwrap(),
            "fresh source text"
        );
        for path in &preserved {
            assert_eq!(fs::read(path).unwrap(), b"preserve");
        }
        assert_eq!(fs::read_dir(root.join(book_key)).unwrap().count(), 2);
        assert!(refresh_chapter_text(&root, "../escape", "0.json", "text").is_err());
        assert!(refresh_chapter_text(&root, &other_key, "../source.epub", "text").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn refreshing_text_rejects_symlinked_book_or_chapter() {
        use std::os::unix::fs::symlink;
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().join("cache");
        let outside = fixture.path().join("outside");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(&outside).unwrap();
        let key = "a".repeat(64);
        symlink(&outside, root.join(&key)).unwrap();
        assert!(refresh_chapter_text(&root, &key, "0.json", "text").is_err());
        fs::remove_file(root.join(&key)).unwrap();
        fs::create_dir(root.join(&key)).unwrap();
        let source = outside.join("book.epub");
        fs::write(&source, b"source").unwrap();
        symlink(&source, root.join(&key).join("0.json")).unwrap();
        assert!(refresh_chapter_text(&root, &key, "0.json", "text").is_err());
        assert_eq!(fs::read(source).unwrap(), b"source");
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
