#![cfg(not(target_arch = "wasm32"))]

use converter_core::{
    audio, cache,
    config::AppConfig,
    epub,
    jobs::JobState,
    paths, piper,
    worker::{ConversionRequest, ConversionWorker, ExecutionOptions, WorkerError},
};
use std::{
    fs,
    io::Write,
    path::Path,
    process::Command,
    sync::{Arc, Mutex},
};
use zip::{write::SimpleFileOptions, ZipWriter};

#[path = "support/worker_execution_fixtures.rs"]
mod worker_execution_fixtures;
use worker_execution_fixtures::{book, waveform, ExplicitRuntime};

#[test]
fn force_and_clear_apply_only_to_selected_chapter_through_actual_worker() {
    const GUARD: &str = "EPUB_FLAGS_ISOLATED_TEST";
    if std::env::var(GUARD).as_deref() != Ok("1") {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "force_and_clear_apply_only_to_selected_chapter_through_actual_worker",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(GUARD, "1")
            .env_remove("PIPER_MODEL")
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
        assert!(String::from_utf8_lossy(&output.stdout).contains("FLAGS_ASSERTIONS_COMPLETED"));
        return;
    }
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path();
    let input = root.join("source.epub");
    book(&input);
    let source = fs::read(&input).unwrap();
    let parsed = epub::parse_epub(std::io::Cursor::new(&source)).unwrap();
    assert_eq!(parsed.chapters.len(), 3);
    let paths = paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_owned(),
    );
    fs::create_dir_all(&paths.piper_models_dir).unwrap();
    let model = paths.piper_models_dir.join("pt_BR-faber-medium.onnx");
    fs::write(&model, b"owned synthetic model").unwrap();
    fs::write(model.with_extension("onnx.json"), b"{}").unwrap();
    let downloads = root.join("download.mp3");
    fs::write(&downloads, b"listener download").unwrap();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let recorded = Arc::clone(&calls);
    piper::register_runtime(Arc::new(piper::RegisteredPiperRuntime::new(
        move |text, target| {
            recorded.lock().unwrap().push(text.to_owned());
            let mut audio = waveform();
            audio[44] = 1;
            fs::write(target, audio).map_err(|error| piper::PiperError::Io(error.to_string()))
        },
    )));
    let cache_dir = paths.cache_dir.join(cache::sha256_bytes(&source));
    fs::create_dir_all(&cache_dir).unwrap();
    for chapter in &parsed.chapters {
        cache::atomic_write_json(
            cache_dir.join(format!("{}.json", chapter.index.replace('.', "_"))),
            &chapter.text,
        )
        .unwrap();
    }
    let selected_cache = cache_dir.join(format!(
        "{}.json",
        parsed.chapters[1].index.replace('.', "_")
    ));
    let unselected_cache: Vec<_> = [0, 2]
        .iter()
        .map(|&index| {
            let path = cache_dir.join(format!(
                "{}.json",
                parsed.chapters[index].index.replace('.', "_")
            ));
            let bytes = fs::read(&path).unwrap();
            (path, bytes)
        })
        .collect();
    for enabled in [false, true] {
        let job = if enabled { "forced-job" } else { "resume-job" };
        let output = paths.output_dir.join(job);
        fs::create_dir_all(&output).unwrap();
        let baseline = ConversionWorker::new(AppConfig::from_paths(paths.clone())).unwrap();
        baseline
            .run(ConversionRequest {
                tts_preferences: None,
                models_root: None,
                input: input.clone(),
                job_id: job.into(),
                engine: Some("piper".into()),
                voice: None,
                language: None,
                piper_model: None,
                piper_config: None,
                chapter_indices: Some(vec!["position:1".into()]),
                no_parallel: true,
            })
            .unwrap();
        calls.lock().unwrap().clear();
        baseline.jobs.delete(job).unwrap();
        let selected_audio = output.join("0001-b.mp3");
        let prior_audio = fs::read(&selected_audio).unwrap();
        let other_audio = [output.join("0001-a.mp3"), output.join("0001-c.mp3")];
        for path in &other_audio {
            fs::write(path, b"unselected audio").unwrap();
        }
        if enabled {
            fs::write(&selected_cache, b"malformed derived text").unwrap();
        }
        let worker = ConversionWorker::new(AppConfig::from_paths(paths.clone()))
            .unwrap()
            .with_execution_options(ExecutionOptions {
                clear_cache: enabled,
                force_reprocess: enabled,
                max_performance: true,
            });
        let result = worker
            .run(ConversionRequest {
                tts_preferences: None,
                models_root: None,
                input: input.clone(),
                job_id: job.into(),
                engine: Some("piper".into()),
                piper_model: None,
                piper_config: None,
                voice: None,
                language: None,
                chapter_indices: Some(vec!["position:1".into()]),
                no_parallel: true,
            })
            .unwrap();
        assert_eq!(result.chapters.len(), 1);
        assert_eq!(result.chapters[0].source_index, 1);
        assert_eq!(calls.lock().unwrap().len(), usize::from(enabled));
        let resulting_audio = fs::read(&selected_audio).unwrap();
        assert!(!resulting_audio.is_empty());
        if !enabled {
            assert_eq!(resulting_audio, prior_audio);
        }
        assert_eq!(
            cache::read_json::<String>(&selected_cache).unwrap(),
            parsed.chapters[1].text
        );
        for path in &other_audio {
            assert_eq!(fs::read(path).unwrap(), b"unselected audio");
        }
        for (path, bytes) in &unselected_cache {
            assert_eq!(&fs::read(path).unwrap(), bytes);
        }
        assert!(fs::read_dir(output).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".conversion-stage-")));
    }
    assert_eq!(
        *calls.lock().unwrap(),
        vec![parsed.chapters[1].text.clone()]
    );
    assert_eq!(fs::read(input).unwrap(), source);
    assert_eq!(fs::read(model).unwrap(), b"owned synthetic model");
    assert_eq!(fs::read(downloads).unwrap(), b"listener download");
    println!("FLAGS_ASSERTIONS_COMPLETED");
}

#[test]
fn cancellation_from_final_chapter_completion_preserves_resumable_audio() {
    const GUARD: &str = "EPUB_FINAL_CHAPTER_CANCEL_ISOLATED_TEST";
    if std::env::var(GUARD).as_deref() != Ok("1") {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "cancellation_from_final_chapter_completion_preserves_resumable_audio",
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
        assert!(String::from_utf8_lossy(&output.stdout)
            .contains("TERMINAL_CANCEL_ASSERTIONS_COMPLETED"));
        return;
    }
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path();
    let input = root.join("source.epub");
    book(&input);
    let paths = paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_owned(),
    );
    fs::create_dir_all(&paths.piper_models_dir).unwrap();
    let model = paths.piper_models_dir.join("pt_BR-faber-medium.onnx");
    let config = model.with_extension("onnx.json");
    fs::write(&model, b"owned synthetic model").unwrap();
    fs::write(&config, b"{}").unwrap();
    let calls = Arc::new(Mutex::new(0));
    let recorded = Arc::clone(&calls);
    piper::register_runtime(Arc::new(piper::RegisteredPiperRuntime::new(
        move |_, target| {
            *recorded.lock().unwrap() += 1;
            fs::write(target, waveform()).map_err(|error| piper::PiperError::Io(error.to_string()))
        },
    )));
    let job = "final-chapter-cancel";
    let output = paths.output_dir.join(job);
    let completed = Arc::new(Mutex::new(Vec::new()));
    let observed = Arc::clone(&completed);
    let expected_output = output.clone();
    let cancel = piper::CancellationToken::default();
    let callback_cancel = cancel.clone();
    let worker = ConversionWorker::new(AppConfig::from_paths(paths.clone()))
        .unwrap()
        .with_cancellation(cancel)
        .with_chapter_completed(Arc::new(move |event| {
            assert_eq!(event.job_id, job);
            assert_eq!(event.chapter_index, 1);
            assert_eq!(event.chapters_completed, 1);
            assert_eq!(event.chapters_total, 1);
            assert_eq!(event.audio_path.parent(), Some(expected_output.as_path()));
            observed.lock().unwrap().push(event.audio_path);
            callback_cancel.cancel();
        }));
    let request = ConversionRequest {
        tts_preferences: None,
        models_root: None,
        input,
        job_id: job.into(),
        engine: Some("piper".into()),
        voice: None,
        language: None,
        piper_model: Some(model),
        piper_config: Some(config),
        chapter_indices: Some(vec!["position:1".into()]),
        no_parallel: true,
    };
    let result = worker.run(request.clone());
    assert_eq!(*calls.lock().unwrap(), 1);
    let completed_audio = completed.lock().unwrap();
    assert_eq!(completed_audio.len(), 1);
    assert!(audio::validate_audio(&completed_audio[0], 1).unwrap() > 0.0);
    let receipt: serde_json::Value =
        cache::read_json(completed_audio[0].with_extension("mp3.complete.json")).unwrap();
    let bytes = fs::read(&completed_audio[0]).unwrap();
    let digest = cache::sha256_bytes(&bytes);
    assert_eq!(receipt["audio_sha256"], digest);
    assert_eq!(receipt["size"], bytes.len() as u64);
    assert!(
        matches!(result, Err(WorkerError::Cancelled)),
        "cancellation in the final chapter callback must prevent job completion"
    );
    assert_eq!(worker.jobs.load(job).unwrap().state, JobState::Cancelled);
    assert!(!output.join("manifest.json").exists());
    assert!(!fs::read_dir(&output).unwrap().any(|entry| entry
        .unwrap()
        .path()
        .extension()
        .is_some_and(|extension| extension == "zip")));
    let resumed_worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
    let resumed = resumed_worker.resume(request).unwrap();
    assert_eq!(
        resumed_worker.jobs.load(job).unwrap().state,
        JobState::Completed
    );
    assert_eq!(resumed.job_id, job);
    assert_eq!(resumed.chapters.len(), 1);
    assert_eq!(resumed.chapters[0].source_index, 1);
    assert!(output.join(&resumed.archive).is_file());
    assert!(output.join("manifest.json").is_file());
    assert_eq!(
        cache::sha256_bytes(&fs::read(&completed_audio[0]).unwrap()),
        digest
    );
    assert_eq!(
        *calls.lock().unwrap(),
        1,
        "resume must reuse the validated completed chapter"
    );
    println!("TERMINAL_CANCEL_ASSERTIONS_COMPLETED");
}
