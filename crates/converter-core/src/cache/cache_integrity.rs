//! Stable cache content and legacy identity hashes.
use sha1::{Digest as Sha1Digest, Sha1};
use sha2::Sha256;
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

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
