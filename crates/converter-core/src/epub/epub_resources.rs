//! One decompressed-read budget for all metadata, navigation, covers and chapters.
use super::{EpubError, EpubReadLimits};
use std::io::{Read, Seek};
use zip::ZipArchive;

pub(super) struct EpubReadBudget {
    limits: EpubReadLimits,
    remaining: u64,
}

impl EpubReadBudget {
    pub(super) fn new(limits: EpubReadLimits) -> Self {
        Self {
            limits,
            remaining: limits.max_total_bytes,
        }
    }
}

pub(super) fn read_entry<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    path: &str,
    budget: &mut EpubReadBudget,
) -> Result<String, EpubError> {
    let bytes = read_resource(archive, path, budget)?;
    String::from_utf8(bytes)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error).into())
}

pub(super) fn read_resource<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    path: &str,
    budget: &mut EpubReadBudget,
) -> Result<Vec<u8>, EpubError> {
    let index = crate::zip_names::member_index(archive, path)?
        .ok_or_else(|| EpubError::MissingResource(path.into()))?;
    let file = archive
        .by_index(index)
        .map_err(|_| EpubError::MissingResource(path.into()))?;
    let allowed = budget.limits.max_resource_bytes.min(budget.remaining);
    let error = if budget.limits.max_resource_bytes <= budget.remaining {
        EpubError::ResourceReadLimit {
            path: path.into(),
            limit: budget.limits.max_resource_bytes,
        }
    } else {
        EpubError::TotalReadLimit {
            path: path.into(),
            limit: budget.limits.max_total_bytes,
        }
    };
    if file.size() > allowed {
        return Err(error);
    }
    // Also bound actual reads instead of trusting ZIP size metadata alone.
    let mut bytes = Vec::new();
    file.take(allowed.saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > allowed {
        return Err(error);
    }
    budget.remaining -= bytes.len() as u64;
    Ok(bytes)
}
