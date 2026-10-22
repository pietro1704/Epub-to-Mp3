use super::*;
use std::time::Duration;

fn manager() -> (tempfile::TempDir, ConversionJobStore) {
    let directory = tempfile::tempdir().unwrap();
    let manager = ConversionJobStore::with_ttl(directory.path(), Duration::from_secs(60)).unwrap();
    (directory, manager)
}

#[test]
fn independent_managers_claim_one_job_without_overwriting_the_winner() {
    let directory = tempfile::tempdir().unwrap();
    let barrier = Arc::new(std::sync::Barrier::new(16));
    let writers: Vec<_> = (0..16)
        .map(|owner| {
            let manager = ConversionJobStore::new(directory.path()).unwrap();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                let mut metadata = serde_json::Map::new();
                metadata.insert("owner".into(), serde_json::json!(owner));
                barrier.wait();
                manager.create(JobRecord::new("shared-identity", metadata))
            })
        })
        .collect();
    let mut winner = None;
    for writer in writers {
        match writer.join().unwrap() {
            Ok(record) => {
                assert!(
                    winner.replace(record).is_none(),
                    "only one claim may succeed"
                );
            }
            Err(JobError::Io(error)) => assert_eq!(error.kind(), io::ErrorKind::AlreadyExists),
            other => panic!("unexpected creation result: {other:?}"),
        }
    }
    let manager = ConversionJobStore::new(directory.path()).unwrap();
    assert_eq!(manager.load("shared-identity").unwrap(), winner.unwrap());
    assert_eq!(manager.list().unwrap().len(), 1);
    // Legitimate updates still atomically replace the owning record.
    manager
        .transition("shared-identity", JobState::Running)
        .unwrap();
    assert_eq!(
        manager.load("shared-identity").unwrap().state,
        JobState::Running
    );
}

#[test]
fn independent_claims_and_interrupted_staging_do_not_block_fresh_jobs() {
    let directory = tempfile::tempdir().unwrap();
    let abandoned = directory.path().join(".job-interrupted.tmp");
    fs::write(
        &abandoned,
        b"incomplete staging owned by a previous process",
    )
    .unwrap();
    let writers: Vec<_> = (0..8)
        .map(|index| {
            let manager = ConversionJobStore::new(directory.path()).unwrap();
            std::thread::spawn(move || {
                manager.create(JobRecord::new(
                    format!("independent-{index}"),
                    Default::default(),
                ))
            })
        })
        .collect();
    for writer in writers {
        writer.join().unwrap().unwrap();
    }
    let manager = ConversionJobStore::new(directory.path()).unwrap();
    assert_eq!(manager.list().unwrap().len(), 8);
    assert_eq!(
        fs::read(abandoned).unwrap(),
        b"incomplete staging owned by a previous process"
    );
}

#[test]
fn progress_after_cancellation_preserves_state_and_terminal_records() {
    let (_directory, manager) = manager();
    let mut metadata = serde_json::Map::new();
    metadata.insert("source".into(), serde_json::json!("original-book"));
    manager
        .create(JobRecord::new("cancelled", metadata))
        .unwrap();
    manager.transition("cancelled", JobState::Running).unwrap();
    let cancelling = manager.request_cancellation("cancelled").unwrap();
    let progress = serde_json::json!({"completed": 2});
    let clone = manager.clone();
    let updated = clone
        .update_progress("cancelled", progress.clone())
        .unwrap();
    assert_eq!(updated.state, JobState::Cancelling);
    assert_eq!(updated.progress, progress);
    assert_eq!(updated.metadata, cancelling.metadata);
    assert_eq!(manager.load("cancelled").unwrap(), updated);

    let terminal = manager
        .transition("cancelled", JobState::Cancelled)
        .unwrap();
    let stored = fs::read(manager.job_path("cancelled")).unwrap();
    assert!(matches!(
        clone.update_progress("cancelled", serde_json::json!({"completed": 3})),
        Err(JobError::InvalidTransition(_))
    ));
    assert_eq!(manager.load("cancelled").unwrap(), terminal);
    assert_eq!(fs::read(manager.job_path("cancelled")).unwrap(), stored);
}

#[test]
fn concurrent_progress_updates_preserve_a_valid_running_job() {
    let (_directory, manager) = manager();
    manager
        .create(JobRecord::new("shared", serde_json::Map::new()))
        .unwrap();
    manager.transition("shared", JobState::Running).unwrap();
    let barrier = Arc::new(std::sync::Barrier::new(16));
    let writers: Vec<_> = (0..16)
        .map(|writer| {
            let manager = manager.clone();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                barrier.wait();
                for step in 0..8 {
                    manager.update_progress(
                        "shared",
                        serde_json::json!({"writer":writer,"step":step}),
                    )?;
                }
                Ok::<_, JobError>(())
            })
        })
        .collect();
    let failures: Vec<_> = writers
        .into_iter()
        .filter_map(|writer| writer.join().expect("writer must not panic").err())
        .collect();
    assert!(
        failures.is_empty(),
        "Concurrent public progress updates failed: {failures:?}"
    );
    assert_eq!(manager.load("shared").unwrap().state, JobState::Running);
}

#[test]
fn concurrent_progress_cannot_erase_durable_cancellation() {
    let (_directory, manager) = manager();
    for round in 0..4 {
        let id = format!("cancel-race-{round}");
        manager
            .create(JobRecord::new(&id, serde_json::Map::new()))
            .unwrap();
        manager.transition(&id, JobState::Running).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(9));
        let writers: Vec<_> = (0..9)
            .map(|writer| {
                let manager = manager.clone();
                let id = id.clone();
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || -> Result<(), JobError> {
                    barrier.wait();
                    if writer == 8 {
                        manager.request_cancellation(&id)?;
                    } else {
                        for step in 0..4 {
                            manager.update_progress(
                                &id,
                                serde_json::json!({"writer":writer,"step":step}),
                            )?;
                        }
                    }
                    Ok(())
                })
            })
            .collect();
        for writer in writers {
            writer.join().unwrap().unwrap();
        }
        assert_eq!(
            manager.load(&id).unwrap().state,
            JobState::Cancelling,
            "A completed cancellation request must survive concurrent progress (round {round})"
        );
    }
}

#[test]
fn restart_resets_recoverable_jobs_and_preserves_completed_jobs() {
    let (_directory, manager) = manager();
    for (index, state) in [
        JobState::Queued,
        JobState::Running,
        JobState::Cancelling,
        JobState::Cancelled,
        JobState::Failed,
    ]
    .into_iter()
    .enumerate()
    {
        let id = format!("retry-{index}");
        let mut record = JobRecord::new(&id, serde_json::Map::new());
        record.state = state;
        record.progress = serde_json::json!({"completed": 2});
        manager.persist(&record).unwrap();
        let restarted = manager.restart(&id).unwrap();
        assert_eq!(restarted.state, JobState::Queued);
        assert!(restarted.progress.is_null());
        assert_eq!(restarted.created_at, record.created_at);
        assert_eq!(manager.load(&id).unwrap(), restarted);
    }
    let mut completed = JobRecord::new("done", serde_json::Map::new());
    completed.state = JobState::Completed;
    manager.persist(&completed).unwrap();
    assert!(matches!(
        manager.restart("done"),
        Err(JobError::InvalidTransition(_))
    ));
    assert_eq!(manager.load("done").unwrap(), completed);
    assert!(matches!(
        manager.restart("unknown"),
        Err(JobError::NotFound(_))
    ));
}

#[test]
fn persists_typed_transitions_and_recovers_active_jobs() {
    let (_directory, manager) = manager();
    manager
        .create(JobRecord::new("job-1", serde_json::Map::new()))
        .unwrap();
    manager.transition("job-1", JobState::Running).unwrap();
    let restarted = ConversionJobStore::new(manager.jobs_dir()).unwrap();
    assert_eq!(
        restarted.recover_active().unwrap(),
        vec![RecoveryItem {
            job_id: "job-1".into(),
            state: JobState::Running
        }]
    );
    assert!(restarted.transition("job-1", JobState::Completed).is_ok());
    assert!(matches!(
        restarted.transition("job-1", JobState::Running),
        Err(JobError::InvalidTransition(_))
    ));
}

#[test]
fn cancellation_is_durable_and_active_jobs_are_ttl_protected() {
    let (_directory, manager) = manager();
    manager
        .create(JobRecord::new("job-2", serde_json::Map::new()))
        .unwrap();
    manager.request_cancellation("job-2").unwrap();
    assert!(manager.is_cancellation_requested("job-2").unwrap());
    assert_eq!(manager.cleanup_stale().unwrap(), 0);
}

#[test]
fn cleanup_removes_expired_terminal_jobs_without_relocking() {
    let (_directory, manager) = manager();
    for (id, state) in [
        ("expired-completed", JobState::Completed),
        ("expired-cancelled", JobState::Cancelled),
        ("expired-failed", JobState::Failed),
        ("old-running", JobState::Running),
    ] {
        let mut record = JobRecord::new(id, serde_json::Map::new());
        record.state = state;
        record.updated_at = 0;
        manager.persist(&record).unwrap();
    }
    let mut recent = JobRecord::new("recent-completed", serde_json::Map::new());
    recent.state = JobState::Completed;
    manager.persist(&recent).unwrap();

    let worker = manager.clone();
    let (sender, receiver) = std::sync::mpsc::channel();
    let cleanup = std::thread::spawn(move || {
        sender.send(worker.cleanup_stale()).unwrap();
    });
    let deleted = receiver
        .recv_timeout(Duration::from_secs(5))
        .expect("cleanup must not recursively acquire the mutation lock")
        .unwrap();
    cleanup.join().unwrap();
    assert_eq!(deleted, 3);
    for id in ["expired-completed", "expired-cancelled", "expired-failed"] {
        assert!(matches!(manager.load(id), Err(JobError::NotFound(_))));
    }
    assert_eq!(
        manager.load("old-running").unwrap().state,
        JobState::Running
    );
    assert_eq!(manager.load("recent-completed").unwrap(), recent);
    assert_eq!(manager.list().unwrap().len(), 2);
    assert_eq!(manager.cleanup_stale().unwrap(), 0);
}
