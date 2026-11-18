//! ZIP serialization shared by EPUB fixtures; callers own document identity,
//! resources and compression so malformed-input tests keep their exact inputs.
use std::io::{Cursor, Write};
use zip::{write::SimpleFileOptions, ZipWriter};

pub fn epub_bytes<N: AsRef<str>, C: AsRef<[u8]>>(
    entries: impl IntoIterator<Item = (N, C)>,
    options: SimpleFileOptions,
) -> Vec<u8> {
    let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
    for (name, contents) in entries {
        archive.start_file(name.as_ref(), options).unwrap();
        archive.write_all(contents.as_ref()).unwrap();
    }
    archive.finish().unwrap().into_inner()
}
