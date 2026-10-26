use super::{tests::*, *};

#[test]
fn full_response_overlap_is_reserved_before_any_download_and_checked_for_overflow() {
    let root = tempfile::tempdir().unwrap();
    let available = INSTALL_SPACE_SAFETY_BYTES + 14;
    let ready = operation(
        root.path(),
        b"12345",
        b"6789",
        available,
        Arc::new(AtomicBool::new(false)),
    );
    assert!(ready.plan().ready);
    assert_eq!(ready.plan().required_bytes, available);
    assert_eq!(ready.plan().event.bytes_completed, 0);
    drop(ready);

    let empty = tempfile::tempdir().unwrap();
    let overflow = ModelInstallOperation::begin_fixture(
        empty.path(),
        fixture_manifest(b"model", b"config"),
        vec![u64::MAX - INSTALL_SPACE_SAFETY_BYTES, 1],
        u64::MAX,
        Arc::new(AtomicBool::new(false)),
    );
    assert!(matches!(overflow, Err(ModelStoreError::InvalidArchive(_))));
    assert!(empty.path().read_dir().unwrap().next().is_none());
}

#[test]
fn terminal_operations_reject_late_mutations_and_cannot_clean_a_new_attempt() {
    for terminal in [
        ModelInstallStage::Completed,
        ModelInstallStage::Failed,
        ModelInstallStage::Cancelled,
    ] {
        let root = tempfile::tempdir().unwrap();
        let first = b"model";
        let second = b"config";
        let mut previous = operation(
            root.path(),
            first,
            second,
            u64::MAX,
            Arc::new(AtomicBool::new(false)),
        );
        match terminal {
            ModelInstallStage::Completed => {
                let first_path = place_download(&previous, 0, first);
                previous.accept_download(0, &first_path).unwrap();
                let second_path = place_download(&previous, 1, second);
                previous.accept_download(1, &second_path).unwrap();
                previous.publish().unwrap();
            }
            ModelInstallStage::Failed => previous.fail("http_failure", "fixture failure").unwrap(),
            ModelInstallStage::Cancelled => previous.cancel().unwrap(),
            _ => unreachable!(),
        }
        let terminal_event = previous.event().clone();
        let mut current = operation(
            root.path(),
            first,
            second,
            u64::MAX,
            Arc::new(AtomicBool::new(false)),
        );
        assert_ne!(current.plan().operation_id, previous.plan().operation_id);
        let first_path = place_download(&current, 0, first);
        let receipt_path = root
            .path()
            .join(".fixture-model.installing/.operation.json");
        let current_receipt = std::fs::read(&receipt_path).unwrap();

        assert!(previous.record_download_progress(0, 1).is_err());
        assert!(previous.accept_download(0, &first_path).is_err());
        assert!(previous.publish().is_err());
        assert!(previous.fail("late_error", "late callback").is_err());
        previous.cancel().unwrap(); // Repeated cancellation is harmless.

        assert_eq!(previous.event(), &terminal_event);
        assert_eq!(std::fs::read(&receipt_path).unwrap(), current_receipt);
        assert_eq!(std::fs::read(&first_path).unwrap(), first);
        current.accept_download(0, &first_path).unwrap();
        let second_path = place_download(&current, 1, second);
        current.accept_download(1, &second_path).unwrap();
        current.publish().unwrap();
        assert_eq!(
            ModelStore::new(root.path())
                .inspect_manifest(&fixture_manifest(first, second))
                .unwrap()
                .state,
            crate::model_store::InstalledModelState::Verified
        );
    }
}

#[test]
fn insufficient_space_is_a_terminal_state_that_cannot_admit_download_progress() {
    let root = tempfile::tempdir().unwrap();
    let mut rejected = operation(
        root.path(),
        b"model",
        b"config",
        0,
        Arc::new(AtomicBool::new(false)),
    );
    let original = rejected.event().clone();
    assert!(matches!(
        rejected.record_download_progress(0, 1),
        Err(ModelStoreError::OperationFinished)
    ));
    assert!(rejected.publish().is_err());
    rejected.cancel().unwrap();
    assert_eq!(rejected.event(), &original);
    assert!(root.path().read_dir().unwrap().next().is_none());
}
