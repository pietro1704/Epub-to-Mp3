#[path = "../../tests/support/epub_fixture.rs"]
mod epub_fixture;

use super::*;
#[path = "captured_request_tests.rs"]
mod captured_request_tests;
#[path = "listening_contract_tests.rs"]
mod listening_contract_tests;
#[path = "low_quality_cache_tests.rs"]
mod low_quality_cache_tests;
#[path = "provider_deadline_tests.rs"]
mod provider_deadline_tests;
#[path = "runtime_revision_cache_identity_tests.rs"]
mod runtime_revision_cache_identity_tests;

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
fn synthesize_native_fixture(
    worker: &ConversionWorker,
    engine: &str,
    text: &str,
    output: &Path,
) -> Result<(), WorkerError> {
    let mut request = preference_test_request();
    request.engine = Some(engine.into());
    let request = worker.capture_request_preferences(request)?;
    worker.synthesize_preferences(
        &request,
        request.tts_preferences.as_ref().unwrap(),
        text,
        output,
        0,
        Some("pt-BR"),
        &std::sync::atomic::AtomicBool::new(false),
        &Mutex::new(Vec::new()),
        1,
    )
}

fn platform_test_book(path: &Path) {
    platform_test_book_with_text(path, "Uma frase para testar a voz offline.");
}
fn platform_test_book_with_text(path: &Path, text: &str) {
    platform_test_book_in_language(path, text, "pt-BR");
}
fn platform_test_book_in_language(path: &Path, text: &str, language: &str) {
    platform_test_book_with_heading(path, text, language, Some("Chapter"));
}
fn platform_test_book_with_heading(path: &Path, text: &str, language: &str, heading: Option<&str>) {
    let heading = heading
        .map(|title| format!("<h1>{title}</h1>"))
        .unwrap_or_default();
    let body = format!("<html><body>{heading}<p>{text}</p></body></html>");
    let package = format!("<package xmlns:dc=\"x\"><metadata><dc:title>System speech</dc:title><dc:language>{language}</dc:language></metadata><manifest><item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"a\"/></spine></package>");
    let bytes = epub_fixture::epub_bytes([
        (
            "META-INF/container.xml",
            "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>",
        ),
        ("content.opf", package.as_str()),
        ("a.xhtml", body.as_str()),
    ], zip::write::SimpleFileOptions::default());
    fs::write(path, bytes).unwrap();
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
include!("session_adapter_tests.rs");
include!("seek_priority_tests.rs");
include!("language_profile_tests.rs");
#[path = "source_chunk_contract_tests.rs"]
mod source_chunk_contract_tests;

/// iPhone 16e, 2026-11-27: the screen stayed at "0 of 130" because progress
/// events raised during synthesis carried a literal zero.
#[test]
fn progress_during_synthesis_reports_the_chapters_already_completed() {
    let root = tempfile::tempdir().unwrap();
    let paths = crate::paths::resolve_paths_from(
        std::collections::HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    );
    let mut worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let observed = seen.clone();
    worker.progress = Some(Arc::new(move |event: ProgressEvent| {
        observed.lock().unwrap().push(event.chapters_completed)
    }));
    {
        let mut progress = worker.render_progress.lock().unwrap();
        *progress = render_progress::RenderProgress::new([(0, 10), (1, 90)]);
        progress.complete(0);
    }
    worker.emit(ProgressEvent {
        render_progress: None,
        job_id: "fixture".into(),
        state: "running".into(),
        chapter_index: Some(1),
        chapters_total: 2,
        chapters_completed: 0,
        percent: 0.0,
        engine: None,
        model_id: None,
        voice: None,
        fallback_used: false,
        message: "fixture".into(),
    });
    assert_eq!(*seen.lock().unwrap(), vec![1]);
}
