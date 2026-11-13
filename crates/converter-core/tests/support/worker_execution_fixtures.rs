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
    for (name, heading, text) in [
        (
            "a",
            "The Morning Market",
            "The first chapter follows a family through the morning market in their English town. They walk between the stalls, choose fresh bread and apples, and speak with neighbors about the weather. After shopping, they carry their bags home and prepare lunch together.",
        ),
        (
            "b",
            "A Walk Through Town",
            "The selected chapter follows the family on a quiet walk through town. They visit the library, read a short story, and meet their friends near the old station. The children describe their favorite books while everyone enjoys the warm afternoon before walking home.",
        ),
        (
            "c",
            "An Evening by the River",
            "The final chapter takes the family beside the river in the evening. They sit beneath the trees, share a simple meal, and watch the boats move slowly past the bridge. As the sun sets, they return to their house and talk about the day.",
        ),
    ] {
        archive
            .start_file(format!("{name}.xhtml"), options)
            .unwrap();
        archive
            .write_all(format!("<html><body><h1>{heading}</h1><p>{text}</p></body></html>").as_bytes())
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
    fn synthesize(
        &self,
        text: &str,
        output: &Path,
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), piper::PiperError> {
        self.text_calls.lock().unwrap().push(text.to_owned());
        fs::write(output, waveform()).map_err(|error| piper::PiperError::Io(error.to_string()))
    }
    fn shutdown(&self) {}
}
