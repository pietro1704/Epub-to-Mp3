use super::*;

#[cfg(unix)]
#[tokio::test]
async fn output_symlinks_cannot_serve_files_outside_the_output_root() {
    let root = TestRoot::new();
    let state = root.state();
    let job_dir = state.config.paths.output_dir.join("symlink-job");
    std::fs::create_dir_all(&job_dir).unwrap();
    let outside = root.0.join("private-file.mp3");
    std::fs::write(&outside, b"private fixture").unwrap();
    std::os::unix::fs::symlink(&outside, job_dir.join("chapter.mp3")).unwrap();
    let response = output(
        AxumPath(("symlink-job".into(), "chapter.mp3".into())),
        State(state.clone()),
        request("GET"),
    )
    .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let outside_dir = root.0.join("private-dir");
    std::fs::create_dir_all(&outside_dir).unwrap();
    std::fs::write(
        outside_dir.join("chapter.mp3"),
        b"private directory fixture",
    )
    .unwrap();
    std::os::unix::fs::symlink(
        &outside_dir,
        state.config.paths.output_dir.join("linked-job"),
    )
    .unwrap();
    let response = output(
        AxumPath(("linked-job".into(), "chapter.mp3".into())),
        State(state),
        request("GET"),
    )
    .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[cfg(unix)]
#[tokio::test]
async fn chapter_manifest_symlink_cannot_escape_the_job_directory() {
    let root = TestRoot::new();
    let state = root.state();
    let job_dir = state.config.paths.output_dir.join("symlink-job");
    std::fs::create_dir_all(&job_dir).unwrap();
    let outside = root.0.join("private-manifest.json");
    std::fs::write(&outside, b"private fixture").unwrap();
    std::os::unix::fs::symlink(&outside, job_dir.join("manifest.json")).unwrap();
    let response = chapters(AxumPath(("symlink-job".into(), 1)), State(state)).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[cfg(unix)]
#[tokio::test]
async fn output_accepts_a_symlink_within_the_job_directory() {
    let root = TestRoot::new();
    let state = root.state();
    let job_dir = state.config.paths.output_dir.join("symlink-job");
    std::fs::create_dir_all(&job_dir).unwrap();
    std::fs::write(job_dir.join("chapter.mp3"), b"audio fixture").unwrap();
    std::os::unix::fs::symlink("chapter.mp3", job_dir.join("alias.mp3")).unwrap();
    let response = output(
        AxumPath(("symlink-job".into(), "alias.mp3".into())),
        State(state),
        request("GET"),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 1024)
        .await
        .unwrap();
    assert_eq!(&bytes[..], b"audio fixture");
}

#[tokio::test]
async fn large_archive_download_is_streamed_in_bounded_chunks() {
    let root = TestRoot::new();
    let state = root.state();
    let job = state.config.paths.output_dir.join("large-job");
    std::fs::create_dir_all(&job).unwrap();
    let size = 4 * 1024 * 1024;
    std::fs::File::create(job.join("book.zip"))
        .unwrap()
        .set_len(size)
        .unwrap();
    let response = output(
        AxumPath(("large-job".into(), "book.zip".into())),
        State(state),
        request("GET"),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::CONTENT_LENGTH], size.to_string());
    assert_eq!(response.headers()[header::CONTENT_TYPE], "application/zip");
    let mut stream = response.into_body().into_data_stream();
    let mut total = 0;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.unwrap();
        assert!(
            chunk.len() <= 64 * 1024,
            "download chunk must remain bounded"
        );
        total += chunk.len() as u64;
    }
    assert_eq!(total, size);
}

#[tokio::test]
async fn head_and_unsatisfiable_range_keep_http_semantics() {
    let root = TestRoot::new();
    let state = root.state();
    let job = state.config.paths.output_dir.join("range-job");
    std::fs::create_dir_all(&job).unwrap();
    std::fs::write(job.join("chapter.mp3"), b"0123456789").unwrap();
    let head = output(
        AxumPath(("range-job".into(), "chapter.mp3".into())),
        State(state.clone()),
        request("HEAD"),
    )
    .await;
    assert_eq!(head.status(), StatusCode::OK);
    assert_eq!(head.headers()[header::CONTENT_LENGTH], "10");
    assert_eq!(head.headers()[header::CONTENT_TYPE], "audio/mpeg");
    assert!(axum::body::to_bytes(head.into_body(), 100)
        .await
        .unwrap()
        .is_empty());
    let mut range = request("GET");
    range
        .headers_mut()
        .insert(header::RANGE, "bytes=20-30".parse().unwrap());
    let response = output(
        AxumPath(("range-job".into(), "chapter.mp3".into())),
        State(state.clone()),
        range,
    )
    .await;
    assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
    assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes */10");
    let missing = output(
        AxumPath(("range-job".into(), "missing.mp3".into())),
        State(state),
        request("GET"),
    )
    .await;
    assert_eq!(missing.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn audio_download_serves_requested_byte_range() {
    let root = TestRoot::new();
    let state = root.state();
    let job = state.config.paths.output_dir.join("range-job");
    std::fs::create_dir_all(&job).unwrap();
    std::fs::write(job.join("chapter.mp3"), b"0123456789").unwrap();
    let response = http_fixture_request(state.config, b"GET /api/outputs/range-job/chapter.mp3 HTTP/1.1\r\nHost: localhost\r\nRange: bytes=2-5\r\nConnection: close\r\n\r\n").await;
    assert!(response.starts_with("HTTP/1.1 206"), "{response}");
    assert!(response
        .to_ascii_lowercase()
        .contains("content-range: bytes 2-5/10"));
    assert!(response.ends_with("2345"));
}

#[test]
fn finished_snapshot_exposes_the_complete_archive() {
    let root = TestRoot::new();
    let state = root.state();
    let job_dir = state.config.paths.output_dir.join("archive-job");
    std::fs::create_dir_all(&job_dir).unwrap();
    std::fs::write(job_dir.join("book.zip"), b"archive fixture").unwrap();
    let manifest = OutputManifest {
        source_chapters_total: None,
        job_id: "archive-job".into(),
        title: "Book".into(),
        author: "Author".into(),
        chapters: Vec::new(),
        archive: "book.zip".into(),
        cover: None,
        tts_preferences: None,
        used_selections: Vec::new(),
        tts_policy_state: Default::default(),
        fallback_used: false,
    };
    let mut snapshot = initial_job("archive-job".into(), &CreateJob::default());
    apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
    let archive = snapshot
        .outputs
        .iter()
        .find(|asset| asset.name == "book.zip")
        .expect("completed archives must be advertised for download");
    assert_eq!(archive.url, "/api/outputs/archive-job/book.zip");
    assert_eq!(archive.size_bytes, 15);
    let value = serde_json::to_value(&snapshot).unwrap();
    assert_eq!(value["outputs"][0]["sizeBytes"], 15);
    std::fs::remove_file(job_dir.join("book.zip")).unwrap();
    apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
    assert!(snapshot.outputs.is_empty());
    std::fs::write(job_dir.join("book.zip"), []).unwrap();
    apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
    assert!(snapshot.outputs.is_empty());
    std::fs::remove_file(job_dir.join("book.zip")).unwrap();
    std::fs::create_dir(job_dir.join("book.zip")).unwrap();
    apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
    assert!(snapshot.outputs.is_empty());
}

#[test]
fn manifest_archive_cannot_escape_the_job_directory() {
    let root = TestRoot::new();
    let state = root.state();
    std::fs::create_dir_all(&state.config.paths.output_dir).unwrap();
    std::fs::write(
        state.config.paths.output_dir.join("outside.zip"),
        b"outside archive",
    )
    .unwrap();
    let manifest = OutputManifest {
        source_chapters_total: None,
        job_id: "archive-job".into(),
        title: "Book".into(),
        author: "Author".into(),
        chapters: Vec::new(),
        archive: "../outside.zip".into(),
        cover: None,
        tts_preferences: None,
        used_selections: Vec::new(),
        tts_policy_state: Default::default(),
        fallback_used: false,
    };
    let mut snapshot = initial_job("archive-job".into(), &CreateJob::default());
    apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
    assert!(snapshot.outputs.is_empty());
}

#[tokio::test]
async fn advertised_archive_can_be_downloaded() {
    let root = TestRoot::new();
    let state = root.state();
    let job_dir = state.config.paths.output_dir.join("archive-job");
    std::fs::create_dir_all(&job_dir).unwrap();
    std::fs::write(job_dir.join("book.zip"), b"download archive").unwrap();
    let manifest = OutputManifest {
        source_chapters_total: None,
        job_id: "archive-job".into(),
        title: "Book".into(),
        author: "Author".into(),
        chapters: Vec::new(),
        archive: "book.zip".into(),
        cover: None,
        tts_preferences: None,
        used_selections: Vec::new(),
        tts_policy_state: Default::default(),
        fallback_used: false,
    };
    let mut snapshot = initial_job("archive-job".into(), &CreateJob::default());
    apply_manifest(&mut snapshot, &manifest, &state.config.paths.output_dir);
    let archive = &snapshot.outputs[0];
    let response = output(
        AxumPath((snapshot.job_id.clone(), archive.name.clone())),
        State(state),
        request("GET"),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 100)
        .await
        .unwrap();
    assert_eq!(bytes.as_ref(), b"download archive");
}

#[tokio::test]
async fn chapter_manifest_rejects_job_path_traversal() {
    let root = TestRoot::new();
    let response = chapters(AxumPath(("../private".into(), 1)), State(root.state())).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn encoded_http_job_path_cannot_escape_outputs() {
    let root = TestRoot::new();
    let state = root.state();
    std::fs::create_dir_all(&state.config.paths.output_dir).unwrap();
    let outside = root.0.join("private");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("example.txt"), b"outside fixture").unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, app(state.config)).await.unwrap();
    });
    let response = tokio::task::spawn_blocking(move || {
        use std::io::{Read, Write};
        let mut client = std::net::TcpStream::connect(address).unwrap();
        client.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
        client.write_all(b"GET /api/outputs/..%2Fprivate/example.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").unwrap();
        let mut bytes = Vec::new();
        client.read_to_end(&mut bytes).unwrap();
        String::from_utf8(bytes).unwrap()
    }).await.unwrap();
    server.abort();
    assert!(response.starts_with("HTTP/1.1 400"), "{response}");
    assert!(!response.contains("outside fixture"));
}

#[tokio::test]
async fn normal_output_download_keeps_its_contents() {
    let root = TestRoot::new();
    let state = root.state();
    let job = state.config.paths.output_dir.join("valid-job");
    std::fs::create_dir_all(&job).unwrap();
    std::fs::write(job.join("chapter.mp3"), b"valid fixture").unwrap();
    let response = output(
        AxumPath(("valid-job".into(), "chapter.mp3".into())),
        State(state),
        request("GET"),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 100)
        .await
        .unwrap();
    assert_eq!(bytes.as_ref(), b"valid fixture");
}

#[tokio::test]
async fn output_rejects_job_ids_that_escape_the_output_root() {
    let root = TestRoot::new();
    let state = root.state();
    std::fs::create_dir_all(&state.config.paths.output_dir).unwrap();
    let outside = root.0.join("private");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("example.txt"), b"outside fixture").unwrap();
    let response = output(
        AxumPath(("../private".into(), "example.txt".into())),
        State(state),
        request("GET"),
    )
    .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}
