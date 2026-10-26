use super::*;
use crate::model_store::ModelArtifact;
use sha2::{Digest, Sha256};

fn fixture_manifest(first: &[u8], second: &[u8]) -> ModelManifest {
    ModelManifest {
        model_id: "fixture-model".into(),
        revision: Some("fixture-revision".into()),
        artifacts: vec![
            ModelArtifact {
                name: "model.onnx".into(),
                url: "https://example.invalid/model.onnx".into(),
                sha256: hex::encode(Sha256::digest(first)),
            },
            ModelArtifact {
                name: "model.onnx.json".into(),
                url: "https://example.invalid/model.onnx.json".into(),
                sha256: hex::encode(Sha256::digest(second)),
            },
        ],
    }
}

fn operation(
    root: &Path,
    first: &[u8],
    second: &[u8],
    available: u64,
    cancellation: Arc<AtomicBool>,
) -> ModelInstallOperation {
    ModelInstallOperation::begin_fixture(
        root,
        fixture_manifest(first, second),
        vec![first.len() as u64, second.len() as u64],
        available,
        cancellation,
    )
    .unwrap()
}

fn place_download(operation: &ModelInstallOperation, index: usize, bytes: &[u8]) -> PathBuf {
    let path = operation.plan().artifacts[index].inbox_path.clone();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, bytes).unwrap();
    path
}

#[test]
fn preflight_reports_exact_insufficient_space_without_creating_staging() {
    let root = tempfile::tempdir().unwrap();
    let operation = operation(
        root.path(),
        b"12345",
        b"6789",
        INSTALL_SPACE_SAFETY_BYTES + 8,
        Arc::new(AtomicBool::new(false)),
    );
    let plan = operation.plan();
    assert!(!plan.ready);
    assert_eq!(plan.required_bytes, INSTALL_SPACE_SAFETY_BYTES + 9);
    assert_eq!(plan.available_bytes, INSTALL_SPACE_SAFETY_BYTES + 8);
    assert_eq!(plan.event.stage, ModelInstallStage::Failed);
    assert_eq!(plan.event.failure.unwrap().kind, "insufficient_space");
    assert!(!root.path().join(".fixture-model.installing").exists());
}

#[test]
fn preflight_rejects_cancelled_and_invalid_catalog_contracts_before_writing() {
    let root = tempfile::tempdir().unwrap();
    let cancellation = Arc::new(AtomicBool::new(true));
    let cancelled = ModelInstallOperation::begin_fixture(
        root.path(),
        fixture_manifest(b"model", b"config"),
        vec![5, 6],
        u64::MAX,
        cancellation,
    );
    assert!(matches!(cancelled, Err(ModelStoreError::Cancelled)));
    assert!(root.path().read_dir().unwrap().next().is_none());

    let mut insecure = fixture_manifest(b"model", b"config");
    insecure.artifacts[0].url = "http://example.invalid/model.onnx".into();
    let rejected = ModelInstallOperation::begin_fixture(
        root.path(),
        insecure,
        vec![5, 6],
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    assert!(matches!(rejected, Err(ModelStoreError::InsecureUrl)));

    let mut malformed = fixture_manifest(b"model", b"config");
    malformed.artifacts[0].sha256 = "not-a-sha256".into();
    let rejected = ModelInstallOperation::begin_fixture(
        root.path(),
        malformed,
        vec![5, 6],
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    assert!(matches!(rejected, Err(ModelStoreError::InvalidArchive(_))));
    assert!(root.path().read_dir().unwrap().next().is_none());
}

#[test]
fn progress_is_monotonic_and_success_publishes_verified_receipt() {
    let root = tempfile::tempdir().unwrap();
    let first = b"verified model";
    let second = b"verified config";
    let mut operation = operation(
        root.path(),
        first,
        second,
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    assert_eq!(
        operation.record_download_progress(0, 3).unwrap().sequence,
        1
    );
    assert_eq!(
        operation
            .record_download_progress(0, 8)
            .unwrap()
            .bytes_completed,
        8
    );
    assert!(matches!(
        operation.record_download_progress(0, 7),
        Err(ModelStoreError::ProgressRegressed { .. })
    ));

    let first_path = place_download(&operation, 0, first);
    operation.accept_download(0, &first_path).unwrap();
    assert_eq!(operation.event().stage, ModelInstallStage::Verifying);
    operation.record_download_progress(1, 3).unwrap();
    assert_eq!(operation.event().stage, ModelInstallStage::Verifying);
    let second_path = place_download(&operation, 1, second);
    operation.accept_download(1, &second_path).unwrap();
    let installed = operation.publish().unwrap();
    assert_eq!(installed.len(), 2);
    assert_eq!(operation.event().stage, ModelInstallStage::Completed);
    assert_eq!(
        operation.event().bytes_completed,
        (first.len() + second.len()) as u64
    );
    let store = ModelStore::new(root.path());
    let inspection = store
        .inspect_manifest(&fixture_manifest(first, second))
        .unwrap();
    assert_eq!(
        inspection.state,
        crate::model_store::InstalledModelState::Verified
    );
}

#[test]
fn checksum_failure_cleans_owned_staging_and_preserves_previous_version() {
    let root = tempfile::tempdir().unwrap();
    let target = root.path().join("fixture-model");
    std::fs::create_dir_all(&target).unwrap();
    std::fs::write(target.join("previous.marker"), b"previous").unwrap();
    let mut operation = operation(
        root.path(),
        b"expected model",
        b"expected config",
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    let path = place_download(&operation, 0, b"wrong payload!");
    let error = operation.accept_download(0, &path).unwrap_err();
    assert!(matches!(error, ModelStoreError::ChecksumMismatch { .. }));
    assert_eq!(operation.event().stage, ModelInstallStage::Failed);
    assert_eq!(
        std::fs::read(target.join("previous.marker")).unwrap(),
        b"previous"
    );
    assert!(!root.path().join(".fixture-model.installing").exists());
    assert!(!root.path().join(".fixture-model.downloads").exists());
}

#[test]
fn missing_download_failure_is_terminal_and_cleans_owned_staging() {
    let root = tempfile::tempdir().unwrap();
    let mut operation = operation(
        root.path(),
        b"expected model",
        b"expected config",
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    let missing = operation.plan().artifacts[0].inbox_path.clone();

    let error = operation.accept_download(0, &missing).unwrap_err();

    assert!(matches!(error, ModelStoreError::Io(_)));
    assert_eq!(operation.event().stage, ModelInstallStage::Failed);
    assert_eq!(
        operation.event().failure.as_ref().unwrap().kind,
        "verification_failed"
    );
    assert!(!root.path().join(".fixture-model.installing").exists());
    assert!(!root.path().join(".fixture-model.downloads").exists());
}

#[test]
fn explicit_transport_failure_cleans_staging_without_touching_previous_version() {
    let root = tempfile::tempdir().unwrap();
    let target = root.path().join("fixture-model");
    std::fs::create_dir_all(&target).unwrap();
    std::fs::write(target.join("previous.marker"), b"previous").unwrap();
    let mut operation = operation(
        root.path(),
        b"model",
        b"config",
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    operation.fail("http_failure", "HTTP 503").unwrap();
    assert_eq!(operation.event().stage, ModelInstallStage::Failed);
    assert_eq!(
        operation.event().failure.as_ref().unwrap().kind,
        "http_failure"
    );
    assert_eq!(
        std::fs::read(target.join("previous.marker")).unwrap(),
        b"previous"
    );
    assert!(!root.path().join(".fixture-model.installing").exists());
}

#[test]
fn cancellation_early_mid_and_late_cleans_staging_and_preserves_previous_version() {
    let payload = vec![b'x'; 160_000];
    for checkpoint in [0usize, 1, 3] {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("fixture-model");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("previous.marker"), b"previous").unwrap();
        let cancellation = Arc::new(AtomicBool::new(false));
        let mut operation = operation(
            root.path(),
            &payload,
            b"config",
            u64::MAX,
            cancellation.clone(),
        );
        let path = place_download(&operation, 0, &payload);
        let error = operation
            .accept_download_with_checkpoints(0, &path, |current| {
                if current == checkpoint {
                    cancellation.store(true, Ordering::Release);
                }
            })
            .unwrap_err();
        assert!(matches!(error, ModelStoreError::Cancelled));
        assert_eq!(operation.event().stage, ModelInstallStage::Cancelled);
        assert_eq!(
            std::fs::read(target.join("previous.marker")).unwrap(),
            b"previous"
        );
        assert!(!root.path().join(".fixture-model.installing").exists());
        assert!(!root.path().join(".fixture-model.downloads").exists());
    }
}

#[test]
fn relaunch_reuses_only_verified_completed_artifacts() {
    let root = tempfile::tempdir().unwrap();
    let first = b"verified model";
    let second = b"verified config";
    let cancellation = Arc::new(AtomicBool::new(false));
    let mut first_process = operation(root.path(), first, second, u64::MAX, cancellation);
    let first_path = place_download(&first_process, 0, first);
    first_process.accept_download(0, &first_path).unwrap();
    drop(first_process);

    let mut relaunched = operation(
        root.path(),
        first,
        second,
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    assert!(relaunched.plan().artifacts[0].accepted);
    assert!(!relaunched.plan().artifacts[1].accepted);
    assert_eq!(
        relaunched.plan().required_bytes,
        second.len() as u64 + INSTALL_SPACE_SAFETY_BYTES
    );
    let second_path = place_download(&relaunched, 1, second);
    relaunched.accept_download(1, &second_path).unwrap();
    relaunched.publish().unwrap();
    assert_eq!(relaunched.event().stage, ModelInstallStage::Completed);
}

#[test]
fn recovery_requires_a_matching_receipt_and_reuses_its_attempt_identity() {
    let root = tempfile::tempdir().unwrap();
    let first = b"verified model";
    let second = b"verified config";
    assert!(ModelInstallOperation::recover_fixture(
        root.path(),
        fixture_manifest(first, second),
        vec![first.len() as u64, second.len() as u64],
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    )
    .unwrap()
    .is_none());

    let first_process = operation(
        root.path(),
        first,
        second,
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    let first_attempt = first_process.plan().operation_id;
    drop(first_process);
    let recovered = ModelInstallOperation::recover_fixture(
        root.path(),
        fixture_manifest(first, second),
        vec![first.len() as u64, second.len() as u64],
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    )
    .unwrap()
    .unwrap();
    assert_eq!(recovered.plan().operation_id, first_attempt);
    drop(recovered);

    let mut cancelled = operation(
        root.path(),
        first,
        second,
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    cancelled.cancel().unwrap();
    drop(cancelled);
    let replacement = operation(
        root.path(),
        first,
        second,
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    assert_ne!(replacement.plan().operation_id, first_attempt);
}

#[test]
fn preflight_restores_a_previous_target_left_by_interrupted_publication() {
    let root = tempfile::tempdir().unwrap();
    let backup = root.path().join(".fixture-model.previous");
    std::fs::create_dir_all(&backup).unwrap();
    std::fs::write(backup.join("previous.marker"), b"previous").unwrap();

    let operation = operation(
        root.path(),
        b"model",
        b"config",
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );

    assert_eq!(
        std::fs::read(root.path().join("fixture-model/previous.marker")).unwrap(),
        b"previous"
    );
    assert!(!backup.exists());
    drop(operation);
}

#[cfg(unix)]
#[test]
fn preflight_removes_an_owned_staging_symlink_without_following_it() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("keep.marker"), b"keep").unwrap();
    let staging = root.path().join(".fixture-model.installing");
    symlink(outside.path(), &staging).unwrap();

    let operation = operation(
        root.path(),
        b"model",
        b"config",
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );

    assert!(staging.is_dir());
    assert!(!std::fs::symlink_metadata(&staging)
        .unwrap()
        .file_type()
        .is_symlink());
    assert_eq!(
        std::fs::read(outside.path().join("keep.marker")).unwrap(),
        b"keep"
    );
    drop(operation);
}

#[test]
fn publication_failure_restores_the_previous_target() {
    let root = tempfile::tempdir().unwrap();
    let target = root.path().join("fixture-model");
    let staging = root.path().join("missing-staging");
    let backup = root.path().join(".fixture-model.previous");
    std::fs::create_dir_all(&target).unwrap();
    std::fs::write(target.join("previous.marker"), b"previous").unwrap();

    let error = publish_directory(&staging, &target, &backup).unwrap_err();

    assert!(matches!(error, ModelStoreError::Io(_)));
    assert_eq!(
        std::fs::read(target.join("previous.marker")).unwrap(),
        b"previous"
    );
    assert!(!backup.exists());
}
