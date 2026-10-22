//! Safe cache paths, owned staging and atomic JSON publication.
use super::CacheError;
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

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

pub(super) fn cache_write_tempfile(parent: &Path) -> io::Result<tempfile::NamedTempFile> {
    tempfile::Builder::new()
        .prefix(".cache-json-")
        .tempfile_in(parent)
}

pub fn read_json<T: for<'de> Deserialize<'de>>(path: impl AsRef<Path>) -> Result<T, CacheError> {
    read_json_from(File::open(path)?)
}

pub(super) fn read_json_from<T: for<'de> Deserialize<'de>>(
    mut reader: impl Read,
) -> Result<T, CacheError> {
    let mut bytes = Vec::new();
    reader
        .read_to_end(&mut bytes)
        .map_err(serde_json::Error::io)?;
    Ok(serde_json::from_slice(&bytes)?)
}
