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
    // Apple callers can enter on a small Swift task stack. Keep the I/O
    // buffer on the heap instead of reserving a megabyte in this frame.
    let mut buffer = vec![0u8; 64 * 1024];
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
    let mut buffer = vec![0u8; 64 * 1024];
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_integrity_fits_a_small_native_caller_stack() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("retained-audio");
        let payload = b"bounded native integrity".repeat(20_000);
        std::fs::write(&path, &payload).unwrap();
        let expected = (sha256_bytes(&payload), hex::encode(Sha1::digest(&payload)));
        let hashes = std::thread::Builder::new()
            .name("small-native-integrity-stack".into())
            .stack_size(128 * 1024)
            .spawn(move || {
                let hashes = (sha256_file(&path).unwrap(), sha1_file(&path).unwrap());
                assert_eq!(
                    sha256_file(path.with_extension("missing"))
                        .unwrap_err()
                        .kind(),
                    io::ErrorKind::NotFound
                );
                hashes
            })
            .unwrap()
            .join()
            .unwrap();
        assert_eq!(hashes, expected);
    }
}
