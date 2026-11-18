#![cfg(not(target_arch = "wasm32"))]

use converter_core::{
    config::AppConfig,
    jobs::JobState,
    paths, piper,
    worker::{retained_chapter_audio_is_intact, ConversionRequest, ConversionWorker, WorkerError},
};
use std::{
    fs,
    process::Command,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

#[allow(dead_code)]
#[path = "support/worker_execution_fixtures.rs"]
mod fixtures;

#[test]
fn cancellation_during_repair_preserves_audio_and_releases_the_job_for_retry() {
    const GUARD: &str = "EPUB_REPAIR_CANCELLATION_ISOLATED_TEST";
    if std::env::var(GUARD).as_deref() != Ok("1") {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "cancellation_during_repair_preserves_audio_and_releases_the_job_for_retry",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(GUARD, "1")
            .env_remove("PIPER_MODEL")
            .env_remove("PIPER_CONFIG")
            .env("PATH", "/no-tools")
            .env("FFMPEG", "/no-tools/ffmpeg")
            .env("FFPROBE", "/no-tools/ffprobe")
            .env("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1")
            .env("RUST_CHAPTER_TIMEOUT_SECONDS", "30")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stdout).contains("REPAIR_CANCELLATION_COMPLETED"));
        return;
    }
    let root = tempfile::tempdir().unwrap();
    let paths = paths::resolve_paths_from(
        [(
            "PERSISTENT_ROOT",
            root.path().to_string_lossy().into_owned(),
        )],
        root.path().to_owned(),
    );
    let input = root.path().join("source.epub");
    fixtures::book(&input);
    fs::create_dir_all(&paths.piper_models_dir).unwrap();
    let model = paths.piper_models_dir.join("en_US-lessac-medium.onnx");
    fs::write(&model, b"synthetic voice model").unwrap();
    let model_config = model.with_extension("onnx.json");
    fs::write(&model_config, b"{}").unwrap();
    let cancellation = piper::CancellationToken::default();
    let cancel_next_synthesis = Arc::new(AtomicBool::new(false));
    let calls = Arc::new(Mutex::new(Vec::new()));
    let (cancel, armed, recorded) = (
        cancellation.clone(),
        cancel_next_synthesis.clone(),
        calls.clone(),
    );
    piper::register_runtime(Arc::new(piper::RegisteredPiperRuntime::new(
        move |text, target, _| {
            recorded.lock().unwrap().push(text.to_owned());
            let mut pending = fixtures::waveform();
            pending[44] = 1;
            fs::write(target, pending).map_err(|error| piper::PiperError::Io(error.to_string()))?;
            // Cancellation happens after synthesis actually starts and writes
            // pending audio, before a replacement chapter can be published.
            if armed.swap(false, Ordering::AcqRel) {
                cancel.cancel();
            }
            Ok(())
        },
    )));
    let request = ConversionRequest {
        input,
        job_id: "cancelled-repair".into(),
        tts_preferences: None,
        models_root: None,
        engine: Some("piper".into()),
        voice: None,
        language: Some("en-US".into()),
        piper_model: Some(model),
        piper_config: Some(model_config),
        chapter_indices: None,
        no_parallel: true,
    };
    let config = AppConfig::from_paths(paths.clone());
    let worker = ConversionWorker::new(config.clone())
        .unwrap()
        .with_cancellation(cancellation.clone());
    let manifest = worker.run(request.clone()).unwrap();
    let original_record = worker.jobs.load(&request.job_id).unwrap();
    calls.lock().unwrap().clear();
    let output = paths.output_dir.join(&request.job_id);
    let audio: Vec<_> = manifest
        .chapters
        .iter()
        .map(|chapter| output.join(&chapter.filename))
        .collect();
    let original_audio: Vec<_> = audio.iter().map(|path| fs::read(path).unwrap()).collect();
    let original_receipts: Vec<_> = audio
        .iter()
        .map(|path| fs::read(path.with_extension("mp3.complete.json")).unwrap())
        .collect();
    let published_manifest = fs::read(output.join("manifest.json")).unwrap();
    let published_archive = fs::read(output.join(&manifest.archive)).unwrap();
    // Remove only this fixture's segment cache so repair reaches the provider.
    fs::remove_dir_all(paths.cache_dir.join("speech-segments-v1")).unwrap();
    let selected_text = converter_core::epub::parse_epub(fs::File::open(&request.input).unwrap())
        .unwrap()
        .chapters[1]
        .text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    cancel_next_synthesis.store(true, Ordering::Release);
    let result = worker.repair_chapters(request.clone(), &[manifest.chapters[1].source_index]);
    assert!(matches!(result, Err(WorkerError::Cancelled)), "{result:?}");
    assert!(cancellation.is_cancelled());
    let interrupted = worker.jobs.load(&request.job_id).unwrap();
    assert_eq!(interrupted.state, JobState::Cancelled);
    assert_eq!(interrupted.created_at, original_record.created_at);
    assert_eq!(interrupted.metadata, original_record.metadata);
    let spoken = std::mem::take(&mut *calls.lock().unwrap());
    assert!(
        !spoken.is_empty(),
        "repair must reach synthesis before cancellation"
    );
    assert!(
        spoken
            .iter()
            .all(|text| selected_text
                .contains(&text.split_whitespace().collect::<Vec<_>>().join(" ")))
    );
    for (index, path) in audio.iter().enumerate() {
        assert_eq!(fs::read(path).unwrap(), original_audio[index]);
        if index != 1 {
            assert!(retained_chapter_audio_is_intact(path));
            assert_eq!(
                fs::read(path.with_extension("mp3.complete.json")).unwrap(),
                original_receipts[index]
            );
        }
    }
    assert!(!audio[1].with_extension("mp3.complete.json").exists());
    assert_eq!(
        fs::read(output.join("manifest.json")).unwrap(),
        published_manifest
    );
    assert_eq!(
        fs::read(output.join(&manifest.archive)).unwrap(),
        published_archive
    );
    // The cancelled worker no longer owns the OS lease, even while its object
    // remains alive. A fresh worker can recover the same durable job.
    let lease = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(
            paths
                .jobs_dir
                .join(".worker-locks")
                .join(format!("{}.lock", request.job_id)),
        )
        .unwrap();
    lease.try_lock().unwrap();
    drop(lease);
    let retry = ConversionWorker::new(config).unwrap();
    let resumed = retry.resume(request.clone()).unwrap();
    assert_eq!(
        retry.jobs.load(&request.job_id).unwrap().state,
        JobState::Completed
    );
    assert_eq!(resumed.job_id, manifest.job_id);
    assert_eq!(resumed.chapters.len(), 3);
    let spoken = calls.lock().unwrap();
    assert!(!spoken.is_empty());
    assert!(
        spoken
            .iter()
            .all(|text| selected_text
                .contains(&text.split_whitespace().collect::<Vec<_>>().join(" ")))
    );
    assert!(audio
        .iter()
        .all(|path| retained_chapter_audio_is_intact(path)));
    for index in [0, 2] {
        assert_eq!(fs::read(&audio[index]).unwrap(), original_audio[index]);
    }
    assert!(output.join(&resumed.archive).is_file());
    println!("REPAIR_CANCELLATION_COMPLETED");
}
