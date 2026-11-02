#![cfg(not(target_arch = "wasm32"))]
use converter_core::book_input::parse_book_reader;
use std::{
    io::{self, Cursor, Read, Seek, SeekFrom, Write},
    path::Path,
};

struct ReadBudget {
    source: Cursor<Vec<u8>>,
    read_before_seek: usize,
    seeks: usize,
}
impl Read for ReadBudget {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.seeks > 0 {
            return self.source.read(buffer);
        }
        let remaining = (256 * 1024usize).saturating_sub(self.read_before_seek);
        if remaining == 0 {
            return Err(io::Error::other("metadata must not buffer the entire EPUB"));
        }
        let limit = buffer.len().min(remaining);
        let count = self.source.read(&mut buffer[..limit])?;
        self.read_before_seek += count;
        Ok(count)
    }
}
impl Seek for ReadBudget {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        self.seeks += 1;
        self.source.seek(position)
    }
}

#[test]
fn metadata_reader_preserves_seekable_epub_input_without_upfront_buffering() {
    let mut archive = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options =
        zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    for (name, text) in [
        ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>"),
        ("content.opf", "<package xmlns:dc=\"x\"><metadata><dc:title>Streaming EPUB</dc:title></metadata><manifest><item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"a\"/></spine></package>"),
        ("a.xhtml", "<html><body><p>Known EPUB text.</p></body></html>"),
    ] {
        archive.start_file(name, options).unwrap(); archive.write_all(text.as_bytes()).unwrap();
    }
    archive
        .start_file("unused-large-image.bin", options)
        .unwrap();
    archive.write_all(&vec![0; 4 * 1024 * 1024]).unwrap();
    let source = archive.finish().unwrap();
    let mut reader = ReadBudget {
        source: Cursor::new(source.into_inner()),
        read_before_seek: 0,
        seeks: 0,
    };
    let book = parse_book_reader(Path::new("large.epub"), &mut reader)
        .expect("metadata must keep seekable EPUB parsing");
    assert_eq!(book.title, "Streaming EPUB");
    assert!(book.chapters[0].text.contains("Known EPUB text"));
    assert!(reader.seeks > 0);
    assert!(reader.read_before_seek < 256 * 1024);
}

struct OversizedPdf;
impl Read for OversizedPdf {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        panic!("oversized PDF must be rejected before reading or allocating its payload")
    }
}
impl Seek for OversizedPdf {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        match position {
            SeekFrom::End(0) => Ok(300 * 1024 * 1024),
            SeekFrom::Start(0) => Ok(0),
            _ => unreachable!(),
        }
    }
}
#[test]
fn oversized_pdf_reader_fails_before_allocating_its_payload() {
    let error = parse_book_reader(Path::new("huge.pdf"), OversizedPdf).unwrap_err();
    assert!(error.to_string().contains("256 MiB"));
}

#[test]
fn worker_preserves_epub_error_identity_for_existing_resume_consumers() {
    use converter_core::{
        config::AppConfig,
        paths::resolve_paths_from,
        worker::{ConversionRequest, ConversionWorker, WorkerError},
    };
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("invalid.epub");
    std::fs::write(&input, b"not a ZIP archive").unwrap();
    let config = AppConfig::from_paths(resolve_paths_from(
        std::collections::HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    ));
    let request = ConversionRequest {
        input,
        job_id: "invalid-epub-identity".into(),
        tts_preferences: None,
        models_root: None,
        engine: Some("piper".into()),
        voice: None,
        language: None,
        piper_model: None,
        piper_config: None,
        chapter_indices: None,
        no_parallel: true,
    };
    let error = ConversionWorker::new(config)
        .unwrap()
        .run(request)
        .unwrap_err();
    assert!(matches!(error, WorkerError::Epub(_)), "{error}");
}
