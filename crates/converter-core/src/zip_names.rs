use std::io::{Read, Seek};

use zip::{result::ZipResult, ZipArchive};

/// Preserve decoded legacy names while retaining ZIP 9's fast raw-name lookup.
pub(crate) fn member_index<R: Read + Seek>(
    archive: &ZipArchive<R>,
    name: &str,
) -> ZipResult<Option<usize>> {
    if let Some(index) = archive.index_for_name(name) {
        return Ok(Some(index));
    }
    for index in 0..archive.len() {
        if let Some(decoded) = archive.name_for_index(index) {
            if decoded?.as_ref() == name {
                return Ok(Some(index));
            }
        }
    }
    Ok(None)
}
