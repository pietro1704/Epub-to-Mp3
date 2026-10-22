use super::*;

struct TestSystem {
    texts: Arc<Mutex<Vec<String>>>,
}
impl PlatformTts for TestSystem {
    fn synthesize_wav(
        &self,
        text: &str,
        _: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), String> {
        if cancelled() {
            return Err("cancelled".into());
        }
        self.texts.lock().unwrap().push(text.into());
        fs::write(output, test_system_wav()).map_err(|e| e.to_string())
    }
}
fn test_system_wav() -> Vec<u8> {
    test_system_wav_at_rate(22050)
}
fn test_system_wav_at_rate(rate: u32) -> Vec<u8> {
    let samples: Vec<i16> = (0..rate / 8)
        .map(|i| ((i as f64 * 440.0 * std::f64::consts::TAU / rate as f64).sin() * 4000.0) as i16)
        .collect();
    let len = (samples.len() * 2) as u32;
    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&rate.to_le_bytes());
    wav.extend_from_slice(&(rate * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&len.to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    wav
}
fn preference_test_request() -> ConversionRequest {
    ConversionRequest {
        input: PathBuf::new(),
        job_id: "policy-test".into(),
        engine: None,
        voice: None,
        language: Some("pt-BR".into()),
        tts_preferences: None,
        models_root: None,
        piper_model: None,
        piper_config: None,
        chapter_indices: None,
        no_parallel: true,
    }
}
fn platform_test_book(path: &Path) {
    platform_test_book_with_text(path, "Uma frase para testar a voz offline.");
}
fn platform_test_book_with_text(path: &Path, text: &str) {
    platform_test_book_in_language(path, text, "pt-BR");
}
fn platform_test_book_in_language(path: &Path, text: &str, language: &str) {
    use std::io::Write;
    let body = format!("<html><body><h1>Chapter</h1><p>{text}</p></body></html>");
    let package = format!("<package xmlns:dc=\"x\"><metadata><dc:title>System speech</dc:title><dc:language>{language}</dc:language></metadata><manifest><item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"a\"/></spine></package>");
    let mut archive = zip::ZipWriter::new(fs::File::create(path).unwrap());
    let options = zip::write::SimpleFileOptions::default();
    for (name, content) in [
        (
            "META-INF/container.xml",
            "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>",
        ),
        ("content.opf", package.as_str()),
        ("a.xhtml", body.as_str()),
    ] {
        archive.start_file(name, options).unwrap();
        archive.write_all(content.as_bytes()).unwrap();
    }
    archive.finish().unwrap();
}

include!("conversion_contract_tests.rs");
include!("chapter_receipt_tests.rs");
include!("chapter_recovery_tests.rs");
include!("chapter_cache_tests.rs");
include!("edge_deadline_tests.rs");
include!("native_continuation_tests.rs");
include!("native_delivery_tests.rs");
include!("native_failure_tests.rs");
include!("typed_cancellation_tests.rs");
include!("typed_fallback_tests.rs");
include!("typed_persistence_tests.rs");
include!("typed_staging_tests.rs");
