#![cfg(not(target_arch = "wasm32"))]

use converter_core::{
    config::AppConfig,
    paths, piper,
    worker::{ConversionRequest, ConversionWorker, ExecutionOptions},
};
use std::{
    fs,
    path::Path,
    process::Command,
    sync::{Arc, Mutex},
};

#[path = "support/worker_execution_fixtures.rs"]
mod worker_execution_fixtures;
use worker_execution_fixtures::{book, ExplicitRuntime};

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
    let root = fixture.path().canonicalize().unwrap();
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
