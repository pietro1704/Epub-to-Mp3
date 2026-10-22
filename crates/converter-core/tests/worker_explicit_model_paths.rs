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
fn explicit_model_reaches_worker_thread_without_environment_override() {
    const GUARD: &str = "EPUB_MODEL_ISOLATED_TEST";
    if std::env::var(GUARD).as_deref() != Ok("1") {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "explicit_model_reaches_worker_thread_without_environment_override",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(GUARD, "1")
            .env("PIPER_MODEL", "/must-not-use-process-model")
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
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("EXPLICIT_MODEL_ASSERTIONS_COMPLETED")
        );
        return;
    }
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path();
    let input = root.join("source.epub");
    book(&input);
    let parsed = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
    let models = root.join("installed");
    let namespace = models.join("chosen-literal-id");
    fs::create_dir_all(&namespace).unwrap();
    let model_path = namespace.join("chosen.onnx");
    let config_path = namespace.join("chosen.config.json");
    fs::write(&model_path, b"synthetic installed model").unwrap();
    fs::write(&config_path, b"{}").unwrap();
    let runtime = Arc::new(ExplicitRuntime {
        model_calls: Mutex::new(Vec::new()),
        text_calls: Mutex::new(Vec::new()),
    });
    let model = piper::PreparedPiperModel::prepare(
        &models,
        "chosen-literal-id",
        Path::new("chosen.onnx"),
        Path::new("chosen.config.json"),
        runtime.clone(),
    )
    .unwrap();
    let paths = paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_owned(),
    );
    let worker = ConversionWorker::new(AppConfig::from_paths(paths))
        .unwrap()
        .with_piper_model(Some(Arc::new(model)));
    let result = worker
        .run(ConversionRequest {
            tts_preferences: None,
            models_root: None,
            input,
            job_id: "explicit-model-job".into(),
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
    assert_eq!(
        *runtime.text_calls.lock().unwrap(),
        vec![parsed.chapters[1].text.clone()]
    );
    let expected = (
        model_path.canonicalize().unwrap(),
        config_path.canonicalize().unwrap(),
    );
    let calls = runtime.model_calls.lock().unwrap();
    assert_eq!(
        calls.len(),
        2,
        "preflight and synthesis must both initialize the requested model"
    );
    assert!(calls.iter().all(|paths| paths == &expected));
    assert_eq!(
        std::env::var("PIPER_MODEL").unwrap(),
        "/must-not-use-process-model"
    );
    assert_eq!(fs::read(model_path).unwrap(), b"synthetic installed model");
    println!("EXPLICIT_MODEL_ASSERTIONS_COMPLETED");
}

#[test]
fn explicit_model_paths_reach_worker_thread_without_environment_override() {
    const GUARD: &str = "EPUB_MODEL_PATHS_ISOLATED_TEST";
    if std::env::var(GUARD).as_deref() != Ok("1") {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "explicit_model_paths_reach_worker_thread_without_environment_override",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(GUARD, "1")
            .env("PIPER_MODEL", "/must-not-use-process-model")
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
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("EXPLICIT_MODEL_ASSERTIONS_COMPLETED")
        );
        return;
    }
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path();
    let input = root.join("source.epub");
    book(&input);
    let parsed = epub::parse_epub(fs::File::open(&input).unwrap()).unwrap();
    let models = root.join("installed");
    let namespace = models.join("chosen-literal-id");
    fs::create_dir_all(&namespace).unwrap();
    let model_path = namespace.join("chosen.onnx");
    let config_path = namespace.join("chosen.config.json");
    fs::write(&model_path, b"synthetic installed model").unwrap();
    fs::write(&config_path, b"{}").unwrap();
    let runtime = Arc::new(ExplicitRuntime {
        model_calls: Mutex::new(Vec::new()),
        text_calls: Mutex::new(Vec::new()),
    });
    piper::register_runtime(runtime.clone());
    let paths = paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_owned(),
    );
    let worker = ConversionWorker::new(AppConfig::from_paths(paths)).unwrap();
    let result = worker
        .run(ConversionRequest {
            tts_preferences: None,
            models_root: None,
            piper_model: Some(model_path.canonicalize().unwrap()),
            piper_config: Some(config_path.canonicalize().unwrap()),
            input,
            job_id: "explicit-model-job".into(),
            engine: Some("piper".into()),
            voice: None,
            language: None,
            chapter_indices: Some(vec!["position:1".into()]),
            no_parallel: true,
        })
        .unwrap();
    assert_eq!(result.chapters.len(), 1);
    assert_eq!(result.chapters[0].source_index, 1);
    assert_eq!(
        *runtime.text_calls.lock().unwrap(),
        vec![parsed.chapters[1].text.clone()]
    );
    let expected = (
        model_path.canonicalize().unwrap(),
        config_path.canonicalize().unwrap(),
    );
    let calls = runtime.model_calls.lock().unwrap();
    assert_eq!(
        calls.len(),
        1,
        "synthesis must initialize the requested model"
    );
    assert!(calls.iter().all(|paths| paths == &expected));
    assert_eq!(
        std::env::var("PIPER_MODEL").unwrap(),
        "/must-not-use-process-model"
    );
    assert_eq!(fs::read(model_path).unwrap(), b"synthetic installed model");
    println!("EXPLICIT_MODEL_ASSERTIONS_COMPLETED");
}
