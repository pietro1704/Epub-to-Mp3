#![cfg(not(target_arch = "wasm32"))]

use converter_core::piper;
use std::{fs, io::Write, path::Path, sync::Mutex};
use zip::{write::SimpleFileOptions, ZipWriter};

pub(super) fn waveform() -> Vec<u8> {
    let pcm = vec![0u8; 16_000];
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36u32 + pcm.len() as u32).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&8_000u32.to_le_bytes());
    bytes.extend_from_slice(&16_000u32.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&pcm);
    bytes
}

pub(super) fn book(path: &Path) {
    let mut archive = ZipWriter::new(fs::File::create(path).unwrap());
    let options = SimpleFileOptions::default();
    archive
        .start_file("META-INF/container.xml", options)
        .unwrap();
    archive
        .write_all(
            br#"<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>"#,
        )
        .unwrap();
    archive.start_file("content.opf", options).unwrap();
    archive.write_all(br#"<package xmlns:dc="x"><metadata><dc:title>Flags fixture</dc:title></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/><itemref idref="c"/></spine></package>"#).unwrap();
    for (name, text) in [
        ("a", "Unselected first chapter."),
        ("b", "Selected chapter regenerated locally."),
        ("c", "Unselected final chapter."),
    ] {
        archive
            .start_file(format!("{name}.xhtml"), options)
            .unwrap();
        archive
            .write_all(format!("<html><body><h1>{name}</h1><p>{text}</p></body></html>").as_bytes())
            .unwrap();
    }
    archive.finish().unwrap();
}

pub(super) struct ExplicitRuntime {
    pub(super) model_calls: Mutex<Vec<(std::path::PathBuf, std::path::PathBuf)>>,
    pub(super) text_calls: Mutex<Vec<String>>,
}
impl piper::PiperRuntime for ExplicitRuntime {
    fn supports_explicit_model_paths(&self) -> bool {
        true
    }
    fn status(&self) -> piper::PiperRuntimeStatus {
        piper::PiperRuntimeStatus {
            runtime_loaded: true,
            model_available: true,
            abi_compatible: true,
            engine_ready: true,
        }
    }
    fn init(&self, model: &Path, config: &Path) -> Result<(), piper::PiperError> {
        self.model_calls
            .lock()
            .unwrap()
            .push((model.to_owned(), config.to_owned()));
        Ok(())
    }
    fn synthesize(&self, text: &str, output: &Path) -> Result<(), piper::PiperError> {
        self.text_calls.lock().unwrap().push(text.to_owned());
        fs::write(output, waveform()).map_err(|error| piper::PiperError::Io(error.to_string()))
    }
    fn shutdown(&self) {}
}
