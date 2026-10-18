#![cfg(not(target_arch = "wasm32"))]

use converter_core::{
    config::AppConfig,
    embedded::{EmbeddedConversionOptions, EmbeddedConversionSession},
    paths, piper,
};
use std::{fs, io::Write, path::Path, process::Command, sync::Arc};
use zip::{write::SimpleFileOptions, ZipWriter};

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
    piper::register_runtime(Arc::new(piper::RegisteredPiperRuntime::new(|_, target| {
        fs::write(target, waveform()).map_err(|error| piper::PiperError::Io(error.to_string()))
    })));
    let first_input = root.join("first.epub");
    let second_input = root.join("second.epub");
    book(&first_input, "First book", "First independent conversion.");
    book(
        &second_input,
        "Second book",
        "Second independent conversion.",
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
    assert_eq!(first.title, "First book");
    assert_eq!(second.title, "Second book");
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
    book(&explicit_input, "Explicit book", "Caller-owned conversion identity.");
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
