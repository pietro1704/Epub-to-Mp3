//! A whole library shelf in one call.
use super::{read_library_metadata, EpubError, LibraryMetadata};
use std::path::PathBuf;

/// Metadata for each book, in the order given.
pub fn read_library_shelf(
    paths: &[PathBuf],
    _cover_max_edge: u32,
) -> Vec<Result<LibraryMetadata, EpubError>> {
    paths
        .iter()
        .map(|path| {
            let file = std::fs::File::open(path)?;
            read_library_metadata(std::io::BufReader::new(file))
        })
        .collect()
}
