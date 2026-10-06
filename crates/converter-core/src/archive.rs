//! ZIP/CBZ archive primitives used by the native conversion pipeline.
//!
//! This module intentionally owns only archive concerns: safe member listing,
//! deterministic natural ordering for comic-book pages, and streaming member
//! extraction. EPUB parsing remains in `epub` and audio bundle creation in
//! `audio`.

use std::fs::File;
use std::io::{self, Read, Seek, Write};
use std::path::{Path, PathBuf};

use thiserror::Error;
use zip::ZipArchive;

const IMAGE_SUFFIXES: &[&str] = &["jpg", "jpeg", "png", "gif", "webp", "bmp"];

#[derive(Debug, Error)]
pub enum ArchiveError {
    #[error("failed to open archive: {0}")]
    Io(#[from] io::Error),
    #[error("invalid ZIP archive: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("archive member is unsafe: {0}")]
    UnsafeMember(String),
    #[error("archive member not found: {0}")]
    MissingMember(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveMember {
    pub name: String,
    pub size: u64,
}

/// Lists regular members while rejecting path traversal and absolute names.
pub fn list_members<R: Read + Seek>(reader: R) -> Result<Vec<ArchiveMember>, ArchiveError> {
    let mut archive = ZipArchive::new(reader)?;
    let mut members = Vec::new();
    for index in 0..archive.len() {
        let entry = archive.by_index(index)?;
        if entry.is_dir() {
            continue;
        }
        validate_member_name(entry.name())?;
        members.push(ArchiveMember {
            name: entry.name().to_owned(),
            size: entry.size(),
        });
    }
    Ok(members)
}

/// Returns image members in deterministic natural filename order, for CBZ.
pub fn list_image_members<R: Read + Seek>(reader: R) -> Result<Vec<ArchiveMember>, ArchiveError> {
    let mut members = list_members(reader)?;
    members.retain(|member| {
        Path::new(&member.name)
            .extension()
            .and_then(|extension| extension.to_str())
            .map(|extension| {
                IMAGE_SUFFIXES
                    .iter()
                    .any(|known| extension.eq_ignore_ascii_case(known))
            })
            .unwrap_or(false)
    });
    members.sort_by(|left, right| natural_compare(&left.name, &right.name));
    Ok(members)
}

/// Extracts one member to a file without buffering the complete payload.
pub fn extract_member<R: Read + Seek>(
    reader: R,
    member_name: &str,
    output: impl AsRef<Path>,
) -> Result<(), ArchiveError> {
    validate_member_name(member_name)?;
    let mut archive = ZipArchive::new(reader)?;
    let mut input = archive
        .by_name(member_name)
        .map_err(|_| ArchiveError::MissingMember(member_name.to_owned()))?;
    let output = output.as_ref();
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temp = output.with_extension(format!("archive-tmp-{}", std::process::id()));
    let result = (|| {
        let mut file = File::create(&temp)?;
        io::copy(&mut input, &mut file)?;
        file.flush()?;
        file.sync_all()?;
        std::fs::rename(&temp, output)?;
        Ok::<_, ArchiveError>(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

fn validate_member_name(name: &str) -> Result<(), ArchiveError> {
    let path = Path::new(name);
    if name.is_empty() || path.is_absolute() || name.starts_with('/') || name.starts_with('\\') {
        return Err(ArchiveError::UnsafeMember(name.to_owned()));
    }
    if path
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(ArchiveError::UnsafeMember(name.to_owned()));
    }
    Ok(())
}

fn natural_compare(left: &str, right: &str) -> std::cmp::Ordering {
    let left_parts = natural_parts(left);
    let right_parts = natural_parts(right);
    left_parts.cmp(&right_parts)
}

fn natural_parts(value: &str) -> Vec<NaturalPart> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut digits = false;
    for character in value.chars() {
        let is_digit = character.is_ascii_digit();
        if !current.is_empty() && is_digit != digits {
            parts.push(if digits {
                NaturalPart::Number(current.parse().unwrap_or(u64::MAX))
            } else {
                NaturalPart::Text(current.to_ascii_lowercase())
            });
            current.clear();
        }
        digits = is_digit;
        current.push(character);
    }
    if !current.is_empty() {
        parts.push(if digits {
            NaturalPart::Number(current.parse().unwrap_or(u64::MAX))
        } else {
            NaturalPart::Text(current.to_ascii_lowercase())
        });
    }
    parts
}

#[derive(Debug, Eq, PartialEq, Ord, PartialOrd)]
enum NaturalPart {
    Number(u64),
    Text(String),
}

#[allow(dead_code)]
fn _path_buf(name: &str) -> PathBuf {
    PathBuf::from(name)
}
