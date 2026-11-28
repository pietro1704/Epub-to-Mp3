//! Converting the same book with the same options after an interrupted job
//! reuses the chapters that job finished, without naming it.
#![cfg(not(target_arch = "wasm32"))]

#[allow(dead_code)]
#[path = "support/worker_execution_fixtures.rs"]
mod fixtures;

use converter_core::{
    config::AppConfig,
    embedded::{EmbeddedConversionOptions, EmbeddedConversionSession},
    paths, piper,
    worker::{retained_chapter_audio_is_intact, ExecutionOptions},
};
use std::{
    fs,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

const MARKERS: [&str; 3] = [
    "morning market",
    "quiet walk through town",
    "beside the river",
];

fn chapters_spoken(calls: &Mutex<Vec<String>>) -> Vec<usize> {
    std::mem::take(&mut *calls.lock().unwrap())
        .iter()
        .filter_map(|text| MARKERS.iter().position(|marker| text.contains(marker)))
        .collect()
}

#[test]
fn a_new_job_resumes_an_interrupted_one_only_for_the_same_book_and_options() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let paths = paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_owned(),
    );
    fs::create_dir_all(&paths.piper_models_dir).unwrap();
    let model = |name: &str, bytes: &[u8]| {
        let path = paths.piper_models_dir.join(name);
        fs::write(&path, bytes).unwrap();
        fs::write(path.with_extension("onnx.json"), b"{}").unwrap();
        path
    };
    let first_model = model("en_US-lessac-medium.onnx", b"owned synthetic model");
    let other_model = model("en_US-amy-medium.onnx", b"another synthetic model");
    let calls = Arc::new(Mutex::new(Vec::new()));
    let fail_final_chapter = Arc::new(AtomicBool::new(true));
    let (recorded, failing) = (calls.clone(), fail_final_chapter.clone());
    piper::register_runtime(Arc::new(piper::RegisteredPiperRuntime::new(
        move |text, target, _| {
            recorded.lock().unwrap().push(text.to_owned());
            if text.contains(MARKERS[2]) && failing.load(Ordering::Acquire) {
                return Err(piper::PiperError::Synthesis("interrupted".into()));
            }
            let mut audio = fixtures::waveform();
            audio[44] = 1;
            fs::write(target, audio).map_err(|error| piper::PiperError::Io(error.to_string()))
        },
    )));
    let input = root.join("source.epub");
    fixtures::book(&input);
    let config = AppConfig::from_paths(paths.clone());
    let options = |job: &str, model: &std::path::Path| EmbeddedConversionOptions {
        job_id: Some(job.into()),
        engine: Some("piper".into()),
        piper_model: Some(model.to_owned()),
        piper_config: Some(model.with_extension("onnx.json")),
        no_parallel: true,
        ..Default::default()
    };
    let convert = |options: EmbeddedConversionOptions| {
        EmbeddedConversionSession::open(&input, options, config.clone())
            .unwrap()
            .convert()
    };

    assert!(convert(options("interrupted", &first_model)).is_err());
    assert_eq!(chapters_spoken(&calls), [0, 1, 2]);
    fail_final_chapter.store(false, Ordering::Release);
    let interrupted_record = fs::read(paths.jobs_dir.join("interrupted.json")).unwrap();

    // Other options synthesize every chapter.
    convert(options("other-voice", &other_model)).unwrap();
    assert_eq!(chapters_spoken(&calls), [0, 1, 2]);

    // Asking for fresh audio ignores the interrupted job.
    for (job, execution_options) in [
        (
            "forced",
            ExecutionOptions {
                force_reprocess: true,
                ..Default::default()
            },
        ),
        (
            "cleared",
            ExecutionOptions {
                clear_cache: true,
                ..Default::default()
            },
        ),
    ] {
        convert(EmbeddedConversionOptions {
            execution_options,
            ..options(job, &first_model)
        })
        .unwrap();
        assert_eq!(chapters_spoken(&calls), [0, 1, 2], "{job}");
    }

    // The shared segment cache is bounded, so a long book evicts its first
    // segments long before it is converted again. Finished chapters must come
    // from the interrupted job itself.
    fs::remove_dir_all(paths.cache_dir.join("speech-segments-v1")).unwrap();

    // The same book and options only synthesize what is missing.
    let resumed = convert(options("resumed", &first_model)).unwrap();
    assert_eq!(chapters_spoken(&calls), [2]);
    assert_eq!(resumed.chapters.len(), 3);
    let output = paths.output_dir.join("resumed");
    assert!(resumed
        .chapters
        .iter()
        .all(|chapter| retained_chapter_audio_is_intact(&output.join(&chapter.filename))));
    assert_eq!(
        fs::read(paths.jobs_dir.join("interrupted.json")).unwrap(),
        interrupted_record
    );
}
