#![cfg(not(target_arch = "wasm32"))]

use converter_core::{
    cache,
    config::AppConfig,
    epub, paths, piper,
    worker::{ConversionRequest, ConversionWorker, ExecutionOptions},
};
use std::{
    fs,
    io::Write,
    path::Path,
    process::Command,
    sync::{Arc, Mutex},
};
use zip::{write::SimpleFileOptions, ZipWriter};

fn waveform() -> Vec<u8> {
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

fn book(path: &Path) {
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

struct ExplicitRuntime {
    model_calls: Mutex<Vec<(std::path::PathBuf, std::path::PathBuf)>>,
    text_calls: Mutex<Vec<String>>,
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

#[test]
fn explicit_overrides_ignore_prepared_default_identity_and_never_fallback_to_it() {
    const GUARD: &str = "EPUB_OVERRIDE_IDENTITY_CHILD";
    if std::env::var(GUARD).as_deref() != Ok("1") {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "explicit_overrides_ignore_prepared_default_identity_and_never_fallback_to_it",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(GUARD, "1")
            .env("PATH", "/no-tools")
            .env("FFMPEG", "/no-tools/ffmpeg")
            .env("FFPROBE", "/no-tools/ffprobe")
            .env("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stdout).contains("OVERRIDE_ASSERTIONS_COMPLETED"));
        return;
    }
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path();
    let input = root.join("source.epub");
    book(&input);
    let models = root.join("installed");
    for id in ["prepared-A", "selected-B"] {
        fs::create_dir_all(models.join(id)).unwrap();
        fs::write(models.join(id).join("model.onnx"), id.as_bytes()).unwrap();
        fs::write(models.join(id).join("model.onnx.json"), b"{}").unwrap();
    }
    let model_a = models.join("prepared-A/model.onnx");
    let model_b = models.join("selected-B/model.onnx").canonicalize().unwrap();
    let config_b = model_b.with_extension("onnx.json");
    let expected = (model_b.clone(), config_b.clone());
    let runtime = Arc::new(ExplicitRuntime {
        model_calls: Mutex::new(Vec::new()),
        text_calls: Mutex::new(Vec::new()),
    });
    piper::register_runtime(runtime.clone());
    let prepare_a = || {
        Arc::new(
            piper::PreparedPiperModel::prepare(
                &models,
                "prepared-A",
                Path::new("model.onnx"),
                Path::new("model.onnx.json"),
                runtime.clone(),
            )
            .unwrap(),
        )
    };
    let paths = paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_owned(),
    );
    for typed in [false, true] {
        let job = if typed { "typed-B" } else { "paths-B" };
        let preferences = typed.then(|| converter_core::tts_preferences::TtsPreferences {
            policy_version: None,
            primary: converter_core::tts_preferences::TtsSelection {
                engine: "piper".into(),
                model_id: Some("selected-B".into()),
                voice: None,
            },
            secondary: None,
            allow_online_fallback: false,
        });
        let request = ConversionRequest {
            input: input.clone(),
            job_id: job.into(),
            engine: Some("piper".into()),
            voice: None,
            language: None,
            tts_preferences: preferences.clone(),
            models_root: typed.then(|| models.clone()),
            piper_model: (!typed).then(|| model_b.clone()),
            piper_config: (!typed).then(|| config_b.clone()),
            chapter_indices: Some(vec!["position:1".into()]),
            no_parallel: true,
        };
        let worker = ConversionWorker::new(AppConfig::from_paths(paths.clone()))
            .unwrap()
            .with_piper_model(Some(prepare_a()));
        runtime.model_calls.lock().unwrap().clear();
        runtime.text_calls.lock().unwrap().clear();
        let manifest = worker.run(request.clone()).unwrap();
        assert_eq!(manifest.source_chapters_total, Some(3));
        assert_eq!(manifest.chapters.len(), 1);
        assert!(!manifest.fallback_used);
        if typed {
            assert_eq!(manifest.tts_preferences, preferences);
            assert_eq!(
                manifest.used_selections,
                vec![preferences.as_ref().unwrap().primary.clone()]
            );
        } else {
            assert_eq!(
                worker.jobs.load(job).unwrap().metadata["piper_model"],
                serde_json::json!(model_b)
            );
        }
        assert!(!runtime.text_calls.lock().unwrap().is_empty());
        assert!(!runtime.model_calls.lock().unwrap().is_empty());
        assert!(runtime
            .model_calls
            .lock()
            .unwrap()
            .iter()
            .all(|paths| paths == &(model_b.clone(), config_b.clone())));
        let audio = paths
            .output_dir
            .join(job)
            .join(&manifest.chapters[0].filename);
        let receipt = audio.with_extension("mp3.complete.json");
        let prior_audio = fs::read(&audio).unwrap();
        let prior_receipt = fs::read(&receipt).unwrap();
        // An ignored prepared default must not contribute its model digest to B's cache.
        fs::write(&model_a, format!("changed unused A for {job}")).unwrap();
        let replay = ConversionWorker::new(AppConfig::from_paths(paths.clone()))
            .unwrap()
            .with_piper_model(Some(prepare_a()));
        replay.jobs.delete(job).unwrap();
        runtime.model_calls.lock().unwrap().clear();
        runtime.text_calls.lock().unwrap().clear();
        replay.run(request.clone()).unwrap();
        assert!(runtime.model_calls.lock().unwrap().is_empty());
        assert!(runtime.text_calls.lock().unwrap().is_empty());
        assert_eq!(fs::read(&audio).unwrap(), prior_audio);
        assert_eq!(fs::read(&receipt).unwrap(), prior_receipt);

        let recovery = converter_core::conversion_control::ConversionControl::default();
        recovery.set_recovery_job(job).unwrap();
        for invalid in ["../foreign", "a/b", "a\\b", "bad\0id"] {
            assert!(recovery.set_recovery_job(invalid).is_err());
            assert_eq!(recovery.recover_job().as_deref(), Some(job));
        }
        let recovered_worker = ConversionWorker::new(AppConfig::from_paths(paths.clone()))
            .unwrap()
            .with_piper_model(Some(prepare_a()))
            .with_control(recovery);
        runtime.model_calls.lock().unwrap().clear();
        runtime.text_calls.lock().unwrap().clear();
        let mut recovered_request = request.clone();
        recovered_request.job_id = format!("recovered-{job}");
        let recovered = recovered_worker.run(recovered_request).unwrap();
        let recovered_audio = paths
            .output_dir
            .join(format!("recovered-{job}"))
            .join(&recovered.chapters[0].filename);
        assert!(runtime.model_calls.lock().unwrap().is_empty());
        assert!(runtime.text_calls.lock().unwrap().is_empty());
        assert_eq!(fs::read(&recovered_audio).unwrap(), prior_audio);
        assert_eq!(
            fs::read(recovered_audio.with_extension("mp3.complete.json")).unwrap(),
            prior_receipt
        );

        let recovery = converter_core::conversion_control::ConversionControl::default();
        recovery.set_recovery_job(job).unwrap();
        let forced_worker = ConversionWorker::new(AppConfig::from_paths(paths.clone()))
            .unwrap()
            .with_piper_model(Some(prepare_a()))
            .with_control(recovery)
            .with_execution_options(ExecutionOptions {
                force_reprocess: true,
                ..ExecutionOptions::default()
            });
        runtime.model_calls.lock().unwrap().clear();
        runtime.text_calls.lock().unwrap().clear();
        let mut forced_request = request.clone();
        forced_request.job_id = format!("forced-recovery-{job}");
        forced_worker.run(forced_request).unwrap();
        assert!(
            !runtime.text_calls.lock().unwrap().is_empty(),
            "Force must synthesize despite a valid predecessor"
        );
        assert!(
            !runtime.model_calls.lock().unwrap().is_empty(),
            "Force must initialize the selected B model"
        );
        assert!(runtime
            .model_calls
            .lock()
            .unwrap()
            .iter()
            .all(|paths| paths == &expected));
        assert_eq!(fs::read(&audio).unwrap(), prior_audio);
        assert_eq!(fs::read(&receipt).unwrap(), prior_receipt);
        let mut predecessor_a = request.clone();
        predecessor_a.job_id = format!("predecessor-A-{job}");
        if typed {
            predecessor_a
                .tts_preferences
                .as_mut()
                .unwrap()
                .primary
                .model_id = Some("prepared-A".into());
        } else {
            predecessor_a.piper_model = Some(model_a.clone());
            predecessor_a.piper_config = Some(model_a.with_extension("onnx.json"));
        }
        let predecessor_a_manifest = ConversionWorker::new(AppConfig::from_paths(paths.clone()))
            .unwrap()
            .with_piper_model(Some(prepare_a()))
            .run(predecessor_a.clone())
            .unwrap();
        let predecessor_a_audio = paths
            .output_dir
            .join(&predecessor_a.job_id)
            .join(&predecessor_a_manifest.chapters[0].filename);
        let predecessor_a_bytes = fs::read(&predecessor_a_audio).unwrap();
        let predecessor_a_receipt = predecessor_a_audio.with_extension("mp3.complete.json");
        let predecessor_a_receipt_bytes = fs::read(&predecessor_a_receipt).unwrap();
        let wrong_model_recovery = converter_core::conversion_control::ConversionControl::default();
        wrong_model_recovery
            .set_recovery_job(&predecessor_a.job_id)
            .unwrap();
        let override_worker = ConversionWorker::new(AppConfig::from_paths(paths.clone()))
            .unwrap()
            .with_piper_model(Some(prepare_a()))
            .with_control(wrong_model_recovery);
        runtime.model_calls.lock().unwrap().clear();
        runtime.text_calls.lock().unwrap().clear();
        let mut override_request = request.clone();
        override_request.job_id = format!("override-recovered-{job}");
        override_worker.run(override_request).unwrap();
        assert!(
            !runtime.text_calls.lock().unwrap().is_empty(),
            "B must not reuse A's predecessor audio"
        );
        assert!(
            !runtime.model_calls.lock().unwrap().is_empty(),
            "A predecessor recovery must reselect B before synthesis"
        );
        assert!(runtime
            .model_calls
            .lock()
            .unwrap()
            .iter()
            .all(|paths| paths == &expected));
        assert_eq!(fs::read(predecessor_a_audio).unwrap(), predecessor_a_bytes);
        assert_eq!(
            fs::read(predecessor_a_receipt).unwrap(),
            predecessor_a_receipt_bytes
        );
        runtime.model_calls.lock().unwrap().clear();
        runtime.text_calls.lock().unwrap().clear();
        let mut invalid = request;
        invalid.job_id = format!("invalid-{job}");
        if typed {
            let preferences = invalid.tts_preferences.as_mut().unwrap();
            preferences.primary.model_id = Some("missing-B".into());
            preferences.secondary = Some(converter_core::tts_preferences::TtsSelection {
                engine: "piper".into(),
                model_id: Some("prepared-A".into()),
                voice: None,
            });
        } else {
            invalid.piper_model = Some(models.join("missing-B.onnx"));
        }
        assert!(replay.run(invalid).is_err());
        assert!(runtime.model_calls.lock().unwrap().is_empty());
        assert!(runtime.text_calls.lock().unwrap().is_empty());
    }
    println!("OVERRIDE_ASSERTIONS_COMPLETED");
}
