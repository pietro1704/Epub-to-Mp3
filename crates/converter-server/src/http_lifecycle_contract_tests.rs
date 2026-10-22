use super::*;

#[tokio::test]
async fn active_sse_stays_open_until_a_terminal_chapter_event() {
    let root = TestRoot::new();
    let state = root.state();
    let snapshot = initial_job("active-job".into(), &CreateJob::default());
    let (events, _) = broadcast::channel(8);
    state.jobs.write().await.insert(
        "active-job".into(),
        Job {
            snapshot: snapshot.clone(),
            events: events.clone(),
            cancellation: Default::default(),
            worker_active: false,
        },
    );
    let response = stream_job(AxumPath("active-job".into()), State(state.clone())).await;
    let mut stream = response.into_body().into_data_stream();
    assert!(stream.next().await.unwrap().is_ok());
    assert!(
        tokio::time::timeout(Duration::from_millis(20), stream.next())
            .await
            .is_err()
    );
    let mut terminal = snapshot;
    terminal.state = "cancelled".into();
    events.send(SseMessage::Chapter(terminal)).unwrap();
    let event = tokio::time::timeout(Duration::from_millis(100), stream.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(String::from_utf8_lossy(&event).contains("cancelled"));
    assert!(matches!(
        tokio::time::timeout(Duration::from_millis(100), stream.next()).await,
        Ok(None)
    ));
}

#[tokio::test]
async fn initially_finished_job_emits_one_snapshot_then_closes_sse() {
    let root = TestRoot::new();
    let state = root.state();
    let mut snapshot = initial_job("finished-job".into(), &CreateJob::default());
    snapshot.state = "finished".into();
    let (events, _) = broadcast::channel(8);
    state.jobs.write().await.insert(
        "finished-job".into(),
        Job {
            snapshot,
            events,
            cancellation: Default::default(),
            worker_active: false,
        },
    );
    let response = stream_job(AxumPath("finished-job".into()), State(state.clone())).await;
    assert_eq!(response.status(), StatusCode::OK);
    let mut stream = response.into_body().into_data_stream();
    let initial = stream.next().await.unwrap().unwrap();
    assert!(String::from_utf8_lossy(&initial).contains("finished"));
    let closed = tokio::time::timeout(Duration::from_millis(100), stream.next()).await;
    assert!(
        matches!(closed, Ok(None)),
        "a terminal initial snapshot must close SSE"
    );
}

#[tokio::test]
async fn restarted_jobs_are_discoverable_through_the_resumable_api() {
    let root = TestRoot::new();
    let state = root.state();
    let queued = initial_job("restart-job".into(), &CreateJob::default());
    persist_snapshot(&state.config, &queued).unwrap();
    let mut completed = initial_job("complete-job".into(), &CreateJob::default());
    completed.state = "completed".into();
    persist_snapshot(&state.config, &completed).unwrap();
    let response = http_fixture_request(
        state.config,
        b"GET /api/jobs/resumable HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    let body = response.split_once("\r\n\r\n").unwrap().1;
    let value: serde_json::Value = serde_json::from_str(body).unwrap();
    assert_eq!(value["count"], 1);
    assert_eq!(value["resumableJobs"][0]["jobId"], "restart-job");
    assert_eq!(value["resumableJobs"][0]["state"], "interrupted");
}

#[tokio::test]
async fn resume_executes_the_worker_with_a_fresh_cancellation_token() {
    let root = TestRoot::new();
    let state = root.state();
    let input_dir = state.config.paths.job_inputs_dir.join("resume-job");
    std::fs::create_dir_all(&input_dir).unwrap();
    std::fs::write(input_dir.join("source.epub"), b"invalid epub fixture").unwrap();
    let previous = ConversionWorker::new(state.config.clone()).unwrap();
    let previous_result = previous.run(ConversionRequest {
        input: input_dir.join("source.epub"),
        job_id: "resume-job".into(),
        engine: None,
        voice: None,
        language: None,
        piper_model: None,
        piper_config: None,
        tts_preferences: None,
        models_root: None,
        chapter_indices: None,
        no_parallel: false,
    });
    assert!(matches!(
        previous_result,
        Err(converter_core::worker::WorkerError::Epub(_))
    ));
    let mut snapshot = initial_job("resume-job".into(), &CreateJob::default());
    snapshot.state = "cancelled".into();
    snapshot.error = Some("Previous attempt cancelled".into());
    let cancellation = converter_core::piper::CancellationToken::default();
    cancellation.cancel();
    let (events, mut receiver) = broadcast::channel(8);
    state.jobs.write().await.insert(
        snapshot.job_id.clone(),
        Job {
            snapshot,
            events,
            cancellation,
            worker_active: false,
        },
    );
    let response = resume_job(AxumPath("resume-job".into()), State(state.clone())).await;
    assert_eq!(response.status(), StatusCode::OK);
    let initial = receiver.recv().await.unwrap();
    assert!(
        matches!(initial, SseMessage::Snapshot(ref s) if s.state == "queued" && s.error.is_none())
    );
    let terminal = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let SseMessage::Snapshot(snapshot) = receiver.recv().await.unwrap() {
                if is_terminal(&snapshot.state) {
                    break snapshot;
                }
            }
        }
    })
    .await
    .expect("resume must launch the actual conversion worker");
    assert_eq!(
        terminal.state, "failed",
        "invalid EPUB must reach parsing rather than remain queued or reuse the cancelled token"
    );
    assert!(terminal
        .error
        .as_deref()
        .unwrap()
        .starts_with("EPUB error:"));
    assert!(!state.jobs.read().await["resume-job"]
        .cancellation
        .is_cancelled());
    assert_eq!(
        load_snapshots(&state.config)["resume-job"].snapshot.state,
        "failed"
    );
}

#[tokio::test]
async fn resume_missing_input_keeps_the_terminal_snapshot() {
    let root = TestRoot::new();
    let state = root.state();
    let mut snapshot = initial_job("missing-input".into(), &CreateJob::default());
    snapshot.state = "interrupted".into();
    let (events, mut receiver) = broadcast::channel(8);
    state.jobs.write().await.insert(
        snapshot.job_id.clone(),
        Job {
            snapshot,
            events,
            cancellation: Default::default(),
            worker_active: false,
        },
    );
    let response = resume_job(AxumPath("missing-input".into()), State(state.clone())).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        state.jobs.read().await["missing-input"].snapshot.state,
        "interrupted"
    );
    assert!(matches!(
        receiver.try_recv(),
        Err(broadcast::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn resume_waits_for_the_previous_worker_to_stop() {
    let root = TestRoot::new();
    let state = root.state();
    let mut snapshot = initial_job("cancelled-job".into(), &CreateJob::default());
    snapshot.state = "cancelled".into();
    let (events, mut receiver) = broadcast::channel(8);
    state.jobs.write().await.insert(
        snapshot.job_id.clone(),
        Job {
            snapshot,
            events,
            cancellation: Default::default(),
            worker_active: true,
        },
    );
    let response = resume_job(AxumPath("cancelled-job".into()), State(state.clone())).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    assert_eq!(
        state.jobs.read().await["cancelled-job"].snapshot.state,
        "cancelled"
    );
    assert!(matches!(
        receiver.try_recv(),
        Err(broadcast::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn resume_running_job_does_not_reset_it() {
    let root = TestRoot::new();
    let state = root.state();
    let mut snapshot = initial_job("running-job".into(), &CreateJob::default());
    snapshot.state = "running".into();
    let (events, mut receiver) = broadcast::channel(8);
    state.jobs.write().await.insert(
        snapshot.job_id.clone(),
        Job {
            snapshot,
            events,
            cancellation: Default::default(),
            worker_active: false,
        },
    );
    let response = resume_job(AxumPath("running-job".into()), State(state.clone())).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        state.jobs.read().await["running-job"].snapshot.state,
        "running"
    );
    assert!(matches!(
        receiver.try_recv(),
        Err(broadcast::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn queued_cancellation_survives_snapshot_recovery() {
    let root = TestRoot::new();
    let state = root.state();
    let snapshot = initial_job("cancel-job".into(), &CreateJob::default());
    persist_snapshot(&state.config, &snapshot).unwrap();
    let (events, _) = broadcast::channel(8);
    state.jobs.write().await.insert(
        snapshot.job_id.clone(),
        Job {
            snapshot,
            events,
            cancellation: Default::default(),
            worker_active: false,
        },
    );
    let response = cancel(AxumPath("cancel-job".into()), State(state.clone())).await;
    assert_eq!(response.status(), StatusCode::OK);
    let recovered = load_snapshots(&state.config);
    assert_eq!(recovered["cancel-job"].snapshot.state, "cancelled");
    assert!(recovered["cancel-job"].snapshot.error.is_none());
}

#[tokio::test]
async fn cancellation_persistence_failure_does_not_report_success() {
    let root = TestRoot::new();
    let state = root.state();
    std::fs::create_dir_all(state.config.paths.jobs_dir.parent().unwrap()).unwrap();
    std::fs::write(&state.config.paths.jobs_dir, b"not a directory").unwrap();
    let snapshot = initial_job("cancel-job".into(), &CreateJob::default());
    let (events, mut receiver) = broadcast::channel(8);
    state.jobs.write().await.insert(
        snapshot.job_id.clone(),
        Job {
            snapshot,
            events,
            cancellation: Default::default(),
            worker_active: false,
        },
    );
    let response = cancel(AxumPath("cancel-job".into()), State(state.clone())).await;
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let jobs = state.jobs.read().await;
    assert_eq!(jobs["cancel-job"].snapshot.state, "queued");
    assert!(!jobs["cancel-job"].cancellation.is_cancelled());
    assert!(matches!(
        receiver.try_recv(),
        Err(broadcast::error::TryRecvError::Empty)
    ));
}
