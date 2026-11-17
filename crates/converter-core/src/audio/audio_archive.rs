//! Same-volume staged ZIP publication for converted chapter artifacts.
use super::AudioError;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

/// Compare a published ZIP with its exact chapter/cover files without extracting
/// entries or buffering whole audio files. Reading every entry also verifies CRCs.
pub fn validate_archive(output: &Path, files: &[(PathBuf, String)]) -> Result<(), AudioError> {
    let mut archive = zip::ZipArchive::new(File::open(output)?)?;
    if archive.len() != files.len() {
        return Err(AudioError::Validation(
            "archive file count differs from the manifest".into(),
        ));
    }
    let mut packed = vec![0; 64 * 1024];
    let mut retained = vec![0; packed.len()];
    for (path, name) in files {
        let mut entry = archive.by_name(name)?;
        let mut original = File::open(path)?;
        if !original.metadata()?.is_file() || entry.size() != original.metadata()?.len() {
            return Err(AudioError::Validation(format!(
                "archive entry '{name}' has a different size"
            )));
        }
        loop {
            let count = entry.read(&mut packed)?;
            if count == 0 {
                break;
            }
            original.read_exact(&mut retained[..count])?;
            if packed[..count] != retained[..count] {
                return Err(AudioError::Validation(format!(
                    "archive entry '{name}' differs from the retained file"
                )));
            }
        }
        if original.read(&mut retained[..1])? != 0 {
            return Err(AudioError::Validation(format!(
                "archive entry '{name}' is incomplete"
            )));
        }
    }
    Ok(())
}

pub fn create_archive(
    output: impl AsRef<Path>,
    files: &[(PathBuf, String)],
) -> Result<(), AudioError> {
    let output = output.as_ref();
    let parent = output
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new()
        .prefix(".archive-")
        .tempdir_in(parent)?;
    let temp = staging.path().join("archive.zip");
    let file = File::create(&temp)?;
    let mut archive = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    let mut buffer = [0u8; 1024 * 1024];
    for (source, name) in files {
        archive.start_file(name, options)?;
        let mut input = File::open(source)?;
        loop {
            let count = input.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            archive.write_all(&buffer[..count])?;
        }
    }
    let file = archive.finish()?;
    file.sync_all()?;
    drop(file);
    fs::rename(temp, output)?;
    Ok(())
}
