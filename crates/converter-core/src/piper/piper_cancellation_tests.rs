use super::*;
use std::time::Instant;

#[test]
fn cancellation_during_encoding_preserves_previous_audio() {
    let fixture = tempfile::tempdir().unwrap();
    let wav = fixture.path().join("input.wav");
    let output = fixture.path().join("audio.mp3");
    super::tests::write_test_wav(&wav);
    fs::write(&output, b"previous audio").unwrap();
    let probes = std::sync::atomic::AtomicUsize::new(0);
    let result = piper_wav_validation::publish_piper_audio_cancellable(&wav, &output, &|| {
        probes.fetch_add(1, std::sync::atomic::Ordering::SeqCst) > 0
    });
    assert!(matches!(result, Err(PiperError::Cancelled)));
    assert_eq!(fs::read(output).unwrap(), b"previous audio");
    assert_eq!(fs::read_dir(fixture.path()).unwrap().count(), 2);
}

#[test]
fn model_transaction_wait_respects_deadline_without_poisoning_lock() {
    let held = piper_runtime_registry::MODEL_TRANSACTION.lock().unwrap();
    let parent = CancellationToken::default();
    let request = parent.with_timeout(Duration::from_millis(20));
    let started = Instant::now();
    assert!(matches!(
        piper_runtime_registry::cancellable_transaction(&request),
        Err(PiperError::Cancelled)
    ));
    assert!(started.elapsed() < Duration::from_millis(250));
    assert!(request.timed_out());
    assert!(!parent.is_cancelled());
    drop(held);
    assert!(piper_runtime_registry::cancellable_transaction(&parent).is_ok());
}

#[test]
fn child_deadline_cannot_extend_parent_and_user_cancellation_reaches_children() {
    let parent = CancellationToken::default();
    let expired = parent.with_timeout(Duration::ZERO);
    assert!(expired.with_timeout(Duration::from_secs(60)).is_cancelled());
    let active = parent.with_timeout(Duration::from_secs(60));
    assert!(!active.is_cancelled());
    parent.cancel();
    assert!(active.is_cancelled());
    assert!(!active.timed_out());
}
