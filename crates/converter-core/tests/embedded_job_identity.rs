#![cfg(not(target_arch = "wasm32"))]

use converter_core::{
    config::AppConfig,
    embedded::{EmbeddedConversionOptions, EmbeddedConversionSession},
    jobs::JobState,
    paths, piper,
    worker::{retained_chapter_audio_is_intact, ExecutionOptions},
};
use std::{
    fs,
    io::Write,
    path::Path,
    process::Command,
    sync::{atomic::AtomicBool, atomic::Ordering, Arc, Mutex},
};
use zip::{write::SimpleFileOptions, ZipWriter};

#[allow(dead_code)]
#[path = "support/worker_execution_fixtures.rs"]
mod worker_execution_fixtures;

fn book(path: &Path, title: &str, text: &str) {
    let mut archive = ZipWriter::new(fs::File::create(path).unwrap());
    let options = SimpleFileOptions::default();
    for (name, contents) in [
        ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>".to_owned()),
        ("content.opf", format!("<package xmlns:dc=\"x\"><metadata><dc:title>{title}</dc:title></metadata><manifest><item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"a\"/></spine></package>")),
        ("a.xhtml", format!("<html><body><h1>{title}</h1><p>{text}</p></body></html>")),
    ] {
        archive.start_file(name, options).unwrap();
        archive.write_all(contents.as_bytes()).unwrap();
    }
    archive.finish().unwrap();
}

fn waveform() -> Vec<u8> {
    let pcm = vec![0u8; 16_000];
    let mut bytes = b"RIFF".to_vec();
    bytes.extend_from_slice(&(36u32 + pcm.len() as u32).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&8_000u32.to_le_bytes());
    bytes.extend_from_slice(&16_000u32.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&pcm);
    bytes
}

#[test]
fn fresh_embedded_sessions_keep_independent_default_job_identity() {
    const GUARD: &str = "EPUB_DEFAULT_JOB_IDENTITY_ISOLATED_TEST";
    if std::env::var(GUARD).as_deref() != Ok("1") {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "fresh_embedded_sessions_keep_independent_default_job_identity",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(GUARD, "1")
            .env_remove("PIPER_MODEL")
            .env_remove("PIPER_CONFIG")
            .env("PATH", "/no-tools")
            .env("FFMPEG", "/no-tools/ffmpeg")
            .env("FFPROBE", "/no-tools/ffprobe")
            .env("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1")
            .env("RUST_CHAPTER_TIMEOUT_SECONDS", "30")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stdout)
            .contains("DEFAULT_JOB_IDENTITY_ASSERTIONS_COMPLETED"));
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let paths = paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_owned(),
    );
    fs::create_dir_all(&paths.piper_models_dir).unwrap();
    let model = paths.piper_models_dir.join("pt_BR-faber-medium.onnx");
    fs::write(&model, b"owned synthetic model").unwrap();
    fs::write(model.with_extension("onnx.json"), b"{}").unwrap();
    piper::register_runtime(Arc::new(piper::RegisteredPiperRuntime::new(
        |_, target, _| {
            fs::write(target, waveform()).map_err(|error| piper::PiperError::Io(error.to_string()))
        },
    )));
    let first_input = root.join("first.epub");
    let second_input = root.join("second.epub");
    book(
        &first_input,
        "The English Story of the River Village",
        "On Monday morning, the family walked through the green village and watched the river flow past the old bridge. They visited the small library, borrowed two books, and read the newspaper while waiting for their friends. This chapter describes ordinary life in England with complete English sentences and familiar words. In the afternoon, everyone returned home to prepare dinner and write letters about the day.",
    );
    book(
        &second_input,
        "The English Story of the Mountain Village",
        "Every Saturday, the neighbors meet at the market in the center of the village. They buy fresh bread, vegetables, and fruit before walking home along the narrow street. Their children play beside the school while the adults talk about books, music, and the weather. After lunch, the family reads together and plans a visit to the coast next week.",
    );
    let config = AppConfig::from_paths(paths.clone());
    let options = EmbeddedConversionOptions {
        engine: Some("piper".into()),
        no_parallel: true,
        ..Default::default()
    };
    let first = EmbeddedConversionSession::open(first_input, options.clone(), config.clone())
        .unwrap()
        .convert()
        .unwrap();
    let first_output = paths.output_dir.join(&first.job_id);
    let first_manifest = fs::read(first_output.join("manifest.json")).unwrap();
    let first_audio = fs::read(first_output.join(&first.chapters[0].filename)).unwrap();
    let second = EmbeddedConversionSession::open(second_input, options.clone(), config.clone())
        .unwrap()
        .convert()
        .expect("a fresh session without a caller job ID must create an independent job");
    assert_ne!(first.job_id, second.job_id);
    assert_eq!(first.title, "The English Story of the River Village");
    assert_eq!(second.title, "The English Story of the Mountain Village");
    assert_eq!(first.chapters.len(), 1);
    assert_eq!(second.chapters.len(), 1);
    assert_eq!(
        fs::read(first_output.join("manifest.json")).unwrap(),
        first_manifest
    );
    assert_eq!(
        fs::read(first_output.join(&first.chapters[0].filename)).unwrap(),
        first_audio
    );
    let second_output = paths.output_dir.join(&second.job_id);
    assert!(second_output.join("manifest.json").is_file());
    assert!(second_output.join(&second.archive).is_file());
    assert!(!fs::read(second_output.join(&second.chapters[0].filename))
        .unwrap()
        .is_empty());
    let explicit_input = root.join("explicit.epub");
    book(
        &explicit_input,
        "The English Story of the Old Harbor",
        "This English chapter follows a sailor who returns to the harbor after many years. He walks along the wooden pier, meets his old friends, and tells them about the distant countries he visited. The community listens carefully and shares a warm meal before sunset.",
    );
    let explicit_session = EmbeddedConversionSession::open(
        explicit_input,
        EmbeddedConversionOptions {
            job_id: Some("caller-owned-job".into()),
            ..options
        },
        config,
    )
    .unwrap();
    let explicit = explicit_session.convert().unwrap();
    assert_eq!(explicit.job_id, "caller-owned-job");
    let explicit_manifest = paths.output_dir.join("caller-owned-job/manifest.json");
    let explicit_snapshot = fs::read(&explicit_manifest).unwrap();
    assert!(matches!(
        explicit_session.convert(),
        Err(converter_core::embedded::EmbeddedConversionError::Conversion(
            converter_core::worker::WorkerError::Job(converter_core::jobs::JobError::Io(error))
        )) if error.kind() == std::io::ErrorKind::AlreadyExists
    ));
    assert_eq!(fs::read(explicit_manifest).unwrap(), explicit_snapshot);
    println!("DEFAULT_JOB_IDENTITY_ASSERTIONS_COMPLETED");
}

/// A separate process holds the same OS lease as a worker until stdin closes.
#[test]
fn job_lease_holder() {
    use std::io::{Read, Write};
    let Some(path) = std::env::var_os("EPUB_JOB_LEASE_PATH") else {
        return;
    };
    let lease = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .unwrap();
    lease.lock().unwrap();
    println!("JOB_LEASE_HELD");
    std::io::stdout().flush().unwrap();
    std::io::stdin().read_to_end(&mut Vec::new()).unwrap();
}

fn assert_concurrent_worker_is_refused(
    session: &EmbeddedConversionSession,
    paths: &paths::Paths,
    audio: &Path,
) {
    use std::io::{BufRead, BufReader};
    use std::process::Stdio;
    let job_path = paths.jobs_dir.join("lifecycle.json");
    let receipt_path = audio.with_extension("mp3.complete.json");
    let before = (
        fs::read(&job_path).unwrap(),
        fs::read(&receipt_path).unwrap(),
    );
    let mut owner = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "job_lease_holder",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(
            "EPUB_JOB_LEASE_PATH",
            paths.jobs_dir.join(".worker-locks/lifecycle.lock"),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdout = BufReader::new(owner.stdout.take().unwrap());
    let mut line = String::new();
    loop {
        assert!(
            stdout.read_line(&mut line).unwrap() > 0,
            "lease holder exited: {line}"
        );
        if line.contains("JOB_LEASE_HELD") {
            break;
        }
        line.clear();
    }
    for refused in [
        session.convert(),
        session.retry_failed(),
        session.repair_chapters(&[0]),
    ] {
        assert!(refused
            .unwrap_err()
            .to_string()
            .contains("owned by another worker"));
    }
    assert_eq!(fs::read(&job_path).unwrap(), before.0);
    assert_eq!(fs::read(&receipt_path).unwrap(), before.1);
    drop(owner.stdin.take());
    assert!(owner.wait().unwrap().success());
}

/// Which fixture chapters the recorded synthesis calls belong to, in call order.
fn chapters_spoken(calls: &Mutex<Vec<String>>) -> Vec<usize> {
    let spoken = std::mem::take(&mut *calls.lock().unwrap());
    spoken
        .iter()
        .map(|text| {
            [
                "morning market",
                "quiet walk through town",
                "beside the river",
            ]
            .iter()
            .position(|marker| text.contains(marker))
            .expect("every call speaks one fixture chapter")
        })
        .collect()
}

#[test]
fn embedded_retry_and_repair_reuse_validated_chapters_and_honor_forced_execution() {
    const GUARD: &str = "EPUB_EMBEDDED_JOB_LIFECYCLE_ISOLATED_TEST";
    if std::env::var(GUARD).as_deref() != Ok("1") {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "embedded_retry_and_repair_reuse_validated_chapters_and_honor_forced_execution",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(GUARD, "1")
            .env_remove("PIPER_MODEL")
            .env_remove("PIPER_CONFIG")
            .env("PATH", "/no-tools")
            .env("FFMPEG", "/no-tools/ffmpeg")
            .env("FFPROBE", "/no-tools/ffprobe")
            .env("CONVERTER_AUDIO_DISABLE_EXTERNAL_TOOLS", "1")
            .env("RUST_CHAPTER_TIMEOUT_SECONDS", "30")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("JOB_LIFECYCLE_ASSERTIONS_COMPLETED")
        );
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let paths = paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.to_owned(),
    );
    fs::create_dir_all(&paths.piper_models_dir).unwrap();
    let model = paths.piper_models_dir.join("pt_BR-faber-medium.onnx");
    fs::write(&model, b"owned synthetic model").unwrap();
    fs::write(model.with_extension("onnx.json"), b"{}").unwrap();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let fail_final_chapter = Arc::new(AtomicBool::new(true));
    let (recorded, failing) = (calls.clone(), fail_final_chapter.clone());
    piper::register_runtime(Arc::new(piper::RegisteredPiperRuntime::new(
        move |text, target, _| {
            recorded.lock().unwrap().push(text.to_owned());
            if text.contains("beside the river") && failing.swap(false, Ordering::AcqRel) {
                return Err(piper::PiperError::Synthesis("injected failure".into()));
            }
            // A non-silent sample keeps forced re-synthesis past audio validation.
            let mut audio = worker_execution_fixtures::waveform();
            audio[44] = 1;
            fs::write(target, audio).map_err(|error| piper::PiperError::Io(error.to_string()))
        },
    )));
    let input = root.join("source.epub");
    worker_execution_fixtures::book(&input);
    let config = AppConfig::from_paths(paths.clone());
    let options = EmbeddedConversionOptions {
        job_id: Some("lifecycle".into()),
        engine: Some("piper".into()),
        no_parallel: true,
        ..Default::default()
    };
    let session = EmbeddedConversionSession::open(&input, options.clone(), config.clone()).unwrap();
    let jobs = converter_core::jobs::ConversionJobStore::new(&paths.jobs_dir).unwrap();
    let output = paths.output_dir.join("lifecycle");

    // A failed chapter fails the job; the retry synthesizes only that chapter.
    assert!(session.convert().is_err());
    assert_eq!(chapters_spoken(&calls), [0, 1, 2]);
    assert_eq!(jobs.load("lifecycle").unwrap().state, JobState::Failed);
    assert!(!output.join("manifest.json").exists());
    let manifest = session.retry_failed().unwrap();
    assert_eq!(chapters_spoken(&calls), [2]);
    assert_eq!(manifest.chapters.len(), 3);
    assert_eq!(jobs.load("lifecycle").unwrap().state, JobState::Completed);
    let audio: Vec<_> = manifest
        .chapters
        .iter()
        .map(|chapter| output.join(&chapter.filename))
        .collect();
    assert!(audio
        .iter()
        .all(|path| retained_chapter_audio_is_intact(path)));
    // A completed job has nothing to retry, and a session without a caller-owned
    // job ID cannot name the job to retry.
    assert!(session.retry_failed().is_err());
    let anonymous = EmbeddedConversionSession::open(
        &input,
        EmbeddedConversionOptions {
            job_id: None,
            ..options.clone()
        },
        config.clone(),
    )
    .unwrap();
    assert!(anonymous.retry_failed().is_err());
    assert!(anonymous.repair().is_err());
    assert!(chapters_spoken(&calls).is_empty());

    assert_concurrent_worker_is_refused(&session, &paths, &audio[0]);
    let original_record = jobs.load("lifecycle").unwrap();
    // Repairing intact output synthesizes nothing; altered audio is replaced.
    session.repair().unwrap();
    assert!(chapters_spoken(&calls).is_empty());
    let untouched = fs::read(&audio[0]).unwrap();
    fs::write(&audio[1], b"truncated").unwrap();
    assert!(!retained_chapter_audio_is_intact(&audio[1]));
    session.repair().unwrap();
    assert_eq!(chapters_spoken(&calls), [1]);
    assert!(retained_chapter_audio_is_intact(&audio[1]));
    assert_eq!(fs::read(&audio[0]).unwrap(), untouched);

    let repaired_record = jobs.load("lifecycle").unwrap();
    assert_eq!(repaired_record.created_at, original_record.created_at);
    assert_eq!(repaired_record.metadata, original_record.metadata);
    // Explicit source positions withdraw receipts only inside the leased repair.
    session
        .repair_chapters(&[manifest.chapters[0].source_index])
        .unwrap();
    assert_eq!(chapters_spoken(&calls), [0]);
    assert!(output.join(&manifest.archive).is_file());

    // The persisted request reopens with the original selection.
    let reopened =
        EmbeddedConversionSession::reopen_job("lifecycle", &input, config.clone()).unwrap();
    assert_eq!(reopened.options(), &options);
    reopened.repair().unwrap();
    assert!(chapters_spoken(&calls).is_empty());
    // Reopened repairs and retries keep their expected source identity.
    let source_bytes = fs::read(&input).unwrap();
    let record_bytes = fs::read(paths.jobs_dir.join("lifecycle.json")).unwrap();
    fs::write(&input, b"different source bytes").unwrap();
    for refused in [reopened.repair_chapters(&[0]), reopened.retry_failed()] {
        assert!(refused.unwrap_err().to_string().contains("source changed"));
    }
    assert_eq!(
        fs::read(paths.jobs_dir.join("lifecycle.json")).unwrap(),
        record_bytes
    );
    assert!(retained_chapter_audio_is_intact(&audio[0]));
    fs::write(&input, source_bytes).unwrap();
    #[cfg(unix)]
    {
        let receipt = audio[0].with_extension("mp3.complete.json");
        let external = root.join("external-receipt.json");
        let original = fs::read(&receipt).unwrap();
        fs::write(&external, &original).unwrap();
        fs::remove_file(&receipt).unwrap();
        std::os::unix::fs::symlink(&external, &receipt).unwrap();
        assert!(reopened
            .repair_chapters(&[0])
            .unwrap_err()
            .to_string()
            .contains("symlink"));
        assert_eq!(fs::read(&external).unwrap(), original);
        assert!(fs::symlink_metadata(&receipt)
            .unwrap()
            .file_type()
            .is_symlink());
        fs::remove_file(&receipt).unwrap();
        fs::write(&receipt, original).unwrap();
    }
    assert!(EmbeddedConversionSession::reopen_job("missing-job", &input, config.clone()).is_err());
    assert!(EmbeddedConversionSession::reopen_job("../lifecycle", &input, config.clone()).is_err());
    // A request filed under another job's name cannot be replayed as that job.
    let requests = paths.jobs_dir.join("requests");
    fs::copy(
        requests.join("lifecycle.json"),
        requests.join("renamed.json"),
    )
    .unwrap();
    assert!(EmbeddedConversionSession::reopen_job("renamed", &input, config.clone()).is_err());

    // Forced execution ignores every retained chapter of the selection.
    let forced = EmbeddedConversionSession::open(
        &input,
        EmbeddedConversionOptions {
            execution_options: ExecutionOptions {
                force_reprocess: true,
                ..Default::default()
            },
            ..options
        },
        config.clone(),
    )
    .unwrap();
    forced.repair().unwrap();
    assert_eq!(chapters_spoken(&calls), [0, 1, 2]);

    // A job recorded as active belongs to another worker and is left alone.
    jobs.delete("lifecycle").unwrap();
    jobs.create(converter_core::jobs::JobRecord::new(
        "lifecycle",
        Default::default(),
    ))
    .unwrap();
    let record = fs::read(paths.jobs_dir.join("lifecycle.json")).unwrap();
    let receipt = fs::read(audio[0].with_extension("mp3.complete.json")).unwrap();
    assert!(session
        .repair_chapters(&[0])
        .unwrap_err()
        .to_string()
        .contains("active"));
    assert_eq!(
        fs::read(paths.jobs_dir.join("lifecycle.json")).unwrap(),
        record
    );
    assert_eq!(
        fs::read(audio[0].with_extension("mp3.complete.json")).unwrap(),
        receipt
    );
    assert!(chapters_spoken(&calls).is_empty());
    println!("JOB_LIFECYCLE_ASSERTIONS_COMPLETED");
}
