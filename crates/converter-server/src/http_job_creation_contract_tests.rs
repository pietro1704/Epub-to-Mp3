use super::*;

async fn create_default_job(state: &AppState, upload_id: &str) -> String {
    let upload = state.config.paths.uploads_dir.join(upload_id);
    std::fs::create_dir_all(&upload).unwrap();
    std::fs::write(upload.join("source.epub"), b"invalid EPUB fixture").unwrap();
    let response = create_job(
        State(state.clone()),
        axum::Json(CreateJob {
            upload_id: Some(upload_id.into()),
            ..Default::default()
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: serde_json::Value = serde_json::from_slice(&body).unwrap();
    body["jobId"].as_str().unwrap().to_owned()
}

async fn terminal_snapshot(state: &AppState, id: &str) -> JobSnapshot {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            {
                let jobs = state.jobs.read().await;
                if jobs[id].snapshot.state.is_terminal() && !jobs[id].worker_active {
                    break jobs[id].snapshot.clone();
                }
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the job must reach a terminal state")
}

#[tokio::test]
async fn conversion_without_its_voice_installs_it_on_demand_before_running() {
    let root = TestRoot::new();
    let mut state = root.state();
    let installed = Arc::new(std::sync::Mutex::new(Vec::new()));
    let calls = installed.clone();
    state.model_installer = Arc::new(move |models_root, model_id| {
        let calls = calls.clone();
        Box::pin(async move {
            calls.lock().unwrap().push(model_id);
            let directory = models_root.join(model_id);
            std::fs::create_dir_all(&directory)?;
            std::fs::write(directory.join("model.onnx"), b"fixture")?;
            std::fs::write(directory.join("model.onnx.json"), b"{}")?;
            Ok(())
        })
    });
    let id = create_default_job(&state, "on-demand-upload").await;
    let snapshot = terminal_snapshot(&state, &id).await;
    assert_eq!(
        *installed.lock().unwrap(),
        [converter_core::tts_preferences::FABER_MODEL_ID]
    );
    assert!(snapshot
        .events
        .contains(&"Installing voice model pt_BR-faber-medium".to_owned()));
    // The invalid fixture proves the worker ran after the installation.
    assert_eq!(snapshot.state, JobPhase::Failed);
    assert!(snapshot
        .error
        .as_deref()
        .unwrap()
        .starts_with("EPUB error:"));
    let request: serde_json::Value = serde_json::from_slice(
        &std::fs::read(state.config.paths.jobs_dir.join(format!("{id}.json"))).unwrap(),
    )
    .unwrap();
    assert!(request["metadata"]["piper_model"]
        .as_str()
        .unwrap()
        .ends_with("pt_BR-faber-medium/model.onnx"));

    // With the voice present, the next job installs nothing.
    let second = create_default_job(&state, "second-upload").await;
    terminal_snapshot(&state, &second).await;
    assert_eq!(installed.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn failed_voice_installation_fails_the_job_without_running_the_worker() {
    let root = TestRoot::new();
    let state = root.state();
    let id = create_default_job(&state, "no-network-upload").await;
    let snapshot = terminal_snapshot(&state, &id).await;
    assert_eq!(snapshot.state, JobPhase::Failed);
    let error = snapshot.error.as_deref().unwrap();
    assert!(
        error.starts_with("Could not install voice model pt_BR-faber-medium:"),
        "{error}"
    );
    assert!(
        !state
            .config
            .paths
            .jobs_dir
            .join(format!("{id}.json"))
            .exists(),
        "the worker must not start without its voice"
    );
    assert_eq!(
        load_snapshots(&state.config)[&id].snapshot.state,
        JobPhase::Failed
    );
}

#[tokio::test]
async fn conversion_that_cannot_be_persisted_leaves_no_job_behind() {
    let root = TestRoot::new();
    let state = root.state();
    let upload = state.config.paths.uploads_dir.join("unpersisted-upload");
    std::fs::create_dir_all(&upload).unwrap();
    std::fs::write(upload.join("source.epub"), b"invalid EPUB fixture").unwrap();
    place_default_voice(&state.config);
    let jobs_dir = &state.config.paths.jobs_dir;
    let attempt = || {
        create_job(
            State(state.clone()),
            axum::Json(CreateJob {
                upload_id: Some("unpersisted-upload".into()),
                ..Default::default()
            }),
        )
    };
    let detail = |response: axum::response::Response| async {
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        String::from_utf8(body.to_vec()).unwrap()
    };
    let no_leftovers = || {
        let inputs = &state.config.paths.job_inputs_dir;
        !inputs.exists() || std::fs::read_dir(inputs).unwrap().next().is_none()
    };

    // The worker exists, but its snapshot cannot be written.
    std::fs::create_dir_all(jobs_dir).unwrap();
    let writable = std::fs::metadata(jobs_dir).unwrap().permissions();
    let mut read_only = writable.clone();
    std::os::unix::fs::PermissionsExt::set_mode(&mut read_only, 0o555);
    std::fs::set_permissions(jobs_dir, read_only).unwrap();
    let unpersisted = detail(attempt().await).await;
    std::fs::set_permissions(jobs_dir, writable).unwrap();
    assert!(unpersisted.contains("Could not persist"), "{unpersisted}");
    assert!(state.jobs.read().await.is_empty());
    assert!(no_leftovers(), "a refused job must not keep its input copy");

    // The worker itself cannot be prepared.
    std::fs::remove_dir_all(jobs_dir).unwrap();
    std::fs::write(jobs_dir, b"not a directory").unwrap();
    let unprepared = detail(attempt().await).await;
    assert!(unprepared.contains("Could not prepare"), "{unprepared}");
    assert!(
        state.jobs.read().await.is_empty(),
        "a job without durable state must not remain queued"
    );
    assert!(no_leftovers(), "a refused job must not keep its input copy");
}

#[tokio::test]
async fn resume_of_a_legacy_snapshot_repeats_the_selection_its_worker_recorded() {
    let root = TestRoot::new();
    let state = root.state();
    let input_dir = state.config.paths.job_inputs_dir.join("legacy-resume");
    std::fs::create_dir_all(&input_dir).unwrap();
    std::fs::write(input_dir.join("source.epub"), b"invalid epub fixture").unwrap();
    let preferences: TtsPreferences = serde_json::from_value(serde_json::json!({
        "primary":{"engine":"edge","model_id":null,"voice":"pt-BR-FranciscaNeural"},
        "secondary":null,"allow_online_fallback":false
    }))
    .unwrap();
    // The worker's durable record keeps the selection it captured.
    let first_attempt =
        ConversionWorker::new(state.config.clone())
            .unwrap()
            .run(ConversionRequest {
                input: input_dir.join("source.epub"),
                job_id: "legacy-resume".into(),
                engine: None,
                voice: None,
                language: None,
                piper_model: None,
                piper_config: None,
                tts_preferences: Some(preferences.clone()),
                models_root: None,
                chapter_indices: None,
                no_parallel: false,
            });
    assert!(first_attempt.is_err());
    // An earlier server stored no typed preferences and overwrote `engine`
    // with the engine of its last progress event.
    let mut snapshot = initial_job("legacy-resume".into(), &CreateJob::default());
    snapshot.state = JobPhase::Failed;
    snapshot.engine = Some("system".into());
    let (events, _receiver) = broadcast::channel(8);
    state.jobs.write().await.insert(
        snapshot.job_id.clone(),
        Job {
            snapshot,
            events,
            cancellation: Default::default(),
            worker_active: false,
        },
    );
    let response = resume_job(AxumPath("legacy-resume".into()), State(state.clone())).await;
    assert_eq!(response.status(), StatusCode::OK);
    let resumed = terminal_snapshot(&state, "legacy-resume").await;
    assert_eq!(resumed.tts_preferences, Some(preferences));
    assert!(resumed.error.as_deref().unwrap().starts_with("EPUB error:"));
}
