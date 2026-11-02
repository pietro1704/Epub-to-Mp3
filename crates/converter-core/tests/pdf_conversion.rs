#![cfg(not(target_arch = "wasm32"))]
#[path = "support/pdf_fixture.rs"]
mod fixture;
use converter_core::{
    config::AppConfig,
    paths::resolve_paths_from,
    platform_tts::PlatformTts,
    tts_preferences::{TtsPreferences, TtsSelection},
    worker::{ConversionRequest, ConversionWorker},
};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};
struct Speech(Arc<Mutex<Vec<String>>>);
impl PlatformTts for Speech {
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
        self.0.lock().unwrap().push(text.into());
        let rate = 24_000u32;
        let mut pcm = Vec::new();
        for i in 0..rate / 4 {
            pcm.extend_from_slice(&(((i as f32 * 0.1).sin() * 5000.0) as i16).to_le_bytes());
        }
        let mut wav = b"RIFF".to_vec();
        wav.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&rate.to_le_bytes());
        wav.extend_from_slice(&(rate * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        wav.extend(pcm);
        std::fs::write(output, wav).map_err(|e| e.to_string())
    }
}
fn request(input: &Path, job: &str) -> ConversionRequest {
    ConversionRequest {
        input: input.into(),
        job_id: job.into(),
        tts_preferences: Some(TtsPreferences {
            policy_version: None,
            primary: TtsSelection {
                session: None,
                engine: "system".into(),
                model_id: None,
                voice: None,
            },
            secondary: None,
            allow_online_fallback: false,
        }),
        models_root: None,
        engine: None,
        voice: None,
        language: Some("pt-BR".into()),
        piper_model: None,
        piper_config: None,
        chapter_indices: Some(vec!["position:1".into()]),
        no_parallel: true,
    }
}
#[test]
fn pdf_worker_converts_selected_outline_to_valid_audio_and_rejects_stale_source_cache() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("book.pdf");
    std::fs::write(
        &input,
        fixture::pdf(
            true,
            &["First section body.", "", "Selected original passage."],
        ),
    )
    .unwrap();
    let config = AppConfig::from_paths(resolve_paths_from(
        std::collections::HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    ));
    let spoken = Arc::new(Mutex::new(Vec::new()));
    let make_worker = || {
        ConversionWorker::new(config.clone())
            .unwrap()
            .with_platform_tts(Arc::new(Speech(spoken.clone())))
    };
    let manifest = make_worker().run(request(&input, "pdf-first")).unwrap();
    assert_eq!(manifest.title, "PDF fixture");
    assert_eq!(manifest.source_chapters_total, Some(2));
    assert_eq!(manifest.chapters.len(), 1);
    assert_eq!(manifest.chapters[0].source_index, 1);
    let audio = config
        .paths
        .output_dir
        .join("pdf-first")
        .join(&manifest.chapters[0].filename);
    assert!(converter_core::audio::validate_audio(&audio, 100).unwrap() > 0.0);
    assert!(spoken
        .lock()
        .unwrap()
        .join(" ")
        .contains("Selected original passage"));
    assert!(!spoken
        .lock()
        .unwrap()
        .join(" ")
        .contains("First section body"));
    spoken.lock().unwrap().clear();
    std::fs::write(
        &input,
        fixture::pdf(
            true,
            &["First section body.", "", "Changed source passage."],
        ),
    )
    .unwrap();
    make_worker().run(request(&input, "pdf-successor")).unwrap();
    assert!(spoken
        .lock()
        .unwrap()
        .join(" ")
        .contains("Changed source passage"));
    assert!(!spoken
        .lock()
        .unwrap()
        .join(" ")
        .contains("Selected original"));
}
#[test]
fn cancelled_pdf_conversion_never_calls_speech_or_publishes_audio() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("book.pdf");
    std::fs::write(&input, fixture::pdf(true, &["First", "", "Last"])).unwrap();
    let config = AppConfig::from_paths(resolve_paths_from(
        std::collections::HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    ));
    let spoken = Arc::new(Mutex::new(Vec::new()));
    let worker = ConversionWorker::new(config.clone())
        .unwrap()
        .with_platform_tts(Arc::new(Speech(spoken.clone())));
    worker.cancel();
    assert!(worker.run(request(&input, "pdf-cancelled")).is_err());
    assert!(spoken.lock().unwrap().is_empty());
    assert!(!config
        .paths
        .output_dir
        .join("pdf-cancelled/manifest.json")
        .exists());
}

#[test]
fn whole_pdf_conversion_skips_blank_audio_without_renumbering_source_pages() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("book.pdf");
    std::fs::write(
        &input,
        fixture::pdf(false, &["First page body.", "", "Third page body."]),
    )
    .unwrap();
    let config = AppConfig::from_paths(resolve_paths_from(
        std::collections::HashMap::<String, String>::new(),
        root.path().to_path_buf(),
    ));
    let spoken = Arc::new(Mutex::new(Vec::new()));
    let worker = ConversionWorker::new(config.clone())
        .unwrap()
        .with_platform_tts(Arc::new(Speech(spoken.clone())));
    let mut full = request(&input, "pdf-all-pages");
    full.chapter_indices = None;
    let manifest = worker.run(full).unwrap();
    assert_eq!(manifest.source_chapters_total, Some(3));
    assert_eq!(
        manifest
            .chapters
            .iter()
            .map(|c| c.source_index)
            .collect::<Vec<_>>(),
        [0, 2]
    );
    assert_eq!(manifest.chapters.len(), 2);
    assert!(spoken
        .lock()
        .unwrap()
        .iter()
        .all(|text| !text.trim().is_empty()));
}
