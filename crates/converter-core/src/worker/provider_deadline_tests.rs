use super::*;
use std::time::{Duration, Instant};

fn isolated(name: &str, timeout: &str) -> bool {
    const GUARD: &str = "EPUB_PIPER_DEADLINE_TEST";
    if std::env::var(GUARD).as_deref() == Ok(name) {
        return false;
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            &format!("worker::tests::provider_deadline_tests::{name}"),
            "--nocapture",
        ])
        .env(GUARD, name)
        .env("RUST_CHAPTER_TIMEOUT_SECONDS", timeout)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    true
}

fn fixture(runtime: crate::piper::RegisteredPiperRuntime) -> (tempfile::TempDir, ConversionWorker) {
    let fixture = tempfile::tempdir().unwrap();
    let paths = crate::paths::resolve_paths_from(
        [(
            "PERSISTENT_ROOT",
            fixture.path().to_string_lossy().into_owned(),
        )],
        fixture.path().to_owned(),
    );
    fs::create_dir_all(&paths.piper_models_dir).unwrap();
    let model = paths.piper_models_dir.join("pt_BR-faber-medium.onnx");
    fs::write(&model, b"synthetic deadline fixture").unwrap();
    fs::write(model.with_extension("onnx.json"), b"{}").unwrap();
    crate::piper::register_runtime(Arc::new(runtime));
    (
        fixture,
        ConversionWorker::new(AppConfig::from_paths(paths)).unwrap(),
    )
}

fn synthesize(worker: &ConversionWorker, output: &Path) -> Result<(), WorkerError> {
    worker.synthesize_with_timeout(
        "piper",
        "Deadline fixture",
        output,
        0,
        None,
        None,
        None,
        None,
        &std::sync::atomic::AtomicBool::new(false),
    )
}

#[test]
fn expired_piper_deadline_does_not_start_or_wait_for_provider() {
    if isolated(
        "expired_piper_deadline_does_not_start_or_wait_for_provider",
        "0",
    ) {
        return;
    }
    let called = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let observed = called.clone();
    let (fixture, worker) = fixture(crate::piper::RegisteredPiperRuntime::new(move |_, _, _| {
        observed.store(true, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(500));
        Err(crate::piper::PiperError::Synthesis(
            "late provider result".into(),
        ))
    }));
    let output = fixture.path().join("speech.wav");
    let started = Instant::now();
    assert!(matches!(
        synthesize(&worker, &output),
        Err(WorkerError::Piper(_))
    ));
    assert!(
        started.elapsed() < Duration::from_millis(250),
        "Expired deadline waited for provider: {:?}",
        started.elapsed()
    );
    assert!(!called.load(Ordering::SeqCst));
    assert!(!output.exists());
}

#[test]
fn active_deadline_reclaims_provider_and_allows_next_request() {
    if isolated(
        "active_deadline_reclaims_provider_and_allows_next_request",
        "1",
    ) {
        return;
    }
    let exited = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let observed = exited.clone();
    let (fixture, worker) = fixture(crate::piper::RegisteredPiperRuntime::new(
        move |_, _, cancelled| {
            let safety = Instant::now();
            while !cancelled() && safety.elapsed() < Duration::from_secs(3) {
                std::thread::sleep(Duration::from_millis(5));
            }
            observed.store(true, Ordering::SeqCst);
            Err(crate::piper::PiperError::Cancelled)
        },
    ));
    let output = fixture.path().join("speech.wav");
    let started = Instant::now();
    assert!(
        matches!(synthesize(&worker, &output), Err(WorkerError::Piper(message)) if message == "chapter synthesis timed out")
    );
    assert!(started.elapsed() < Duration::from_millis(1800));
    assert!(exited.load(Ordering::SeqCst));
    assert!(!output.exists());
    assert!(
        !worker.cancel.is_cancelled(),
        "A chapter deadline must not cancel another request"
    );
    crate::piper::register_runtime(Arc::new(crate::piper::RegisteredPiperRuntime::new(
        |_, output, _| {
            fs::write(output, test_system_wav())
                .map_err(|error| crate::piper::PiperError::Io(error.to_string()))
        },
    )));
    synthesize(&worker, &output).unwrap();
    assert!(output.is_file());
}

#[test]
fn cancellation_keeps_identity_and_reclaims_active_provider() {
    if isolated(
        "cancellation_keeps_identity_and_reclaims_active_provider",
        "30",
    ) {
        return;
    }
    let (fixture, worker) = fixture(crate::piper::RegisteredPiperRuntime::new(
        |_, _, cancelled| {
            let safety = Instant::now();
            while !cancelled() && safety.elapsed() < Duration::from_secs(3) {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(crate::piper::PiperError::Cancelled)
        },
    ));
    let output = fixture.path().join("speech.wav");
    let started = Instant::now();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            std::thread::sleep(Duration::from_millis(40));
            worker.cancel.cancel();
        });
        assert!(matches!(
            synthesize(&worker, &output),
            Err(WorkerError::Cancelled)
        ));
    });
    assert!(started.elapsed() < Duration::from_millis(500));
    assert!(!output.exists());
    crate::piper::register_runtime(Arc::new(crate::piper::RegisteredPiperRuntime::new(
        |_, _, _| panic!("cancelled request started provider"),
    )));
    assert!(matches!(
        synthesize(&worker, &output),
        Err(WorkerError::Cancelled)
    ));
}

#[test]
fn late_audio_is_discarded_and_provider_errors_are_preserved() {
    if isolated(
        "late_audio_is_discarded_and_provider_errors_are_preserved",
        "1",
    ) {
        return;
    }
    let (fixture, worker) = fixture(crate::piper::RegisteredPiperRuntime::new(|_, output, _| {
        std::thread::sleep(Duration::from_millis(1100));
        fs::write(output, test_system_wav())
            .map_err(|error| crate::piper::PiperError::Io(error.to_string()))
    }));
    let output = fixture.path().join("speech.wav");
    assert!(
        matches!(synthesize(&worker, &output), Err(WorkerError::Piper(message)) if message == "chapter synthesis timed out")
    );
    assert!(!output.exists());
    assert!(!fs::read_dir(fixture.path()).unwrap().any(|entry| entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with(".piper-audio-")));
    crate::piper::register_runtime(Arc::new(crate::piper::RegisteredPiperRuntime::new(
        |_, _, _| Err(crate::piper::PiperError::EmptyOutput),
    )));
    assert!(
        matches!(synthesize(&worker, &output), Err(WorkerError::Piper(message)) if message.contains("empty or missing"))
    );
}
