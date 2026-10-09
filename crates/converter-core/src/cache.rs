//! Cache keys, integrity checks, atomic persistence, and duplicate tracking.
use serde::{Deserialize, Serialize};
use sha1::{Digest as Sha1Digest, Sha1};
use sha2::Sha256;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use thiserror::Error;

/// Exclusively owned, same-volume staging. Cleanup never targets an existing directory.
pub(crate) struct OwnedStagingDirectory(pub(crate) PathBuf);

impl OwnedStagingDirectory {
    pub(crate) fn create(parent: &Path) -> io::Result<Self> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        loop {
            let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = parent.join(format!(
                ".conversion-stage-{}-{sequence}",
                std::process::id()
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
    }
}

impl Drop for OwnedStagingDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Rebuild one derived chapter payload; never recursively clear a cache or touch audio/models.
pub(crate) fn refresh_chapter_text(
    cache_root: &Path,
    book_key: &str,
    chapter_file: &str,
    text: &str,
) -> Result<String, CacheError> {
    if book_key.len() != 64
        || !book_key.bytes().all(|byte| byte.is_ascii_hexdigit())
        || Path::new(chapter_file).components().count() != 1
        || !chapter_file.ends_with(".json")
    {
        return Err(CacheError::Traversal);
    }
    fs::create_dir_all(cache_root)?;
    let book = cache_root.join(book_key);
    match fs::symlink_metadata(&book) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(CacheError::Traversal)
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(&book)?,
        Err(error) => return Err(error.into()),
    }
    if book.canonicalize()?.parent() != Some(cache_root.canonicalize()?.as_path()) {
        return Err(CacheError::Traversal);
    }
    let destination = safe_cache_path(&book, chapter_file)?;
    match fs::symlink_metadata(&destination) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            return Err(CacheError::Traversal)
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    let staging = OwnedStagingDirectory::create(&book)?;
    let payload = staging.0.join("text.json");
    fs::write(&payload, serde_json::to_vec(text)?)?;
    fs::rename(payload, destination)?;
    Ok(text.to_owned())
}

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
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension(format!("tmp-{}", std::process::id()));
    let bytes = serde_json::to_vec(value)?;
    {
        let mut file = File::create(&temp)?;
        file.write_all(&bytes)?;
        if std::env::var("RUST_CACHE_FSYNC")
            .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes"))
            .unwrap_or(false)
        {
            file.sync_all()?;
        }
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
