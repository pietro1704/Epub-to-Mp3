#![cfg(target_os = "linux")]

use converter_core::{
    cache,
    config::AppConfig,
    embedded::{EmbeddedConversionOptions, EmbeddedConversionSession},
    paths::resolve_paths_from,
    tts_preferences::TtsPreferences,
};
use std::{fs, io::Write, path::Path, process::Command};
use zip::{write::SimpleFileOptions, ZipArchive, ZipWriter};

fn session(
    root: &Path,
    job_id: &str,
    preferences: TtsPreferences,
) -> (EmbeddedConversionSession, std::path::PathBuf) {
    let input = root.join("english.epub");
    let mut archive = ZipWriter::new(fs::File::create(&input).unwrap());
    let options = SimpleFileOptions::default();
    archive
        .start_file("META-INF/container.xml", options)
        .unwrap();
    archive
        .write_all(
            br#"<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>"#,
        )
        .unwrap();
    archive.start_file("content.opf", options).unwrap();
    archive.write_all(br#"<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Installed fallback</dc:title><dc:language>en</dc:language></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>"#).unwrap();
    for (name, text) in [
        ("a", "The first chapter uses installed English speech."),
        (
            "b",
            "The second chapter keeps the original voice preferences.",
        ),
    ] {
        archive
            .start_file(format!("{name}.xhtml"), options)
            .unwrap();
        archive
            .write_all(format!("<html><body><h1>{name}</h1><p>{text}</p></body></html>").as_bytes())
            .unwrap();
    }
    archive.finish().unwrap();
    let paths = resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_path_buf())],
        root.to_path_buf(),
    );
    let output = paths.output_dir.join(job_id);
    let session = EmbeddedConversionSession::open(
        &input,
        EmbeddedConversionOptions {
            job_id: Some(job_id.into()),
            tts_preferences: Some(preferences),
            models_root: Some(root.join("no-installed-models")),
            chapter_indices: Some(vec!["position:0".into(), "position:1".into()]),
            no_parallel: true,
            ..Default::default()
        },
        AppConfig::from_paths(paths),
    )
    .unwrap();
    assert_eq!(session.metadata().language.as_deref(), Some("en"));
    (session, output)
}

#[test]
fn installed_native_speech_produces_valid_audio_through_embedded_fallback() {
    if std::env::var_os("EPUB_TEST_NATIVE_TTS").is_none() {
        return;
    }
    let root = tempfile::tempdir().unwrap();
    let preferences = TtsPreferences::app_default(true);
    let (session, output) = session(root.path(), "embedded-native", preferences.clone());
    let manifest = session
        .convert()
        .expect("embedded native fallback must be wired");
    assert_eq!(manifest.job_id, "embedded-native");
    assert_eq!(manifest.tts_preferences.as_ref(), Some(&preferences));
    assert_eq!(
        session.options().tts_preferences.as_ref(),
        Some(&preferences)
    );
    assert!(manifest.fallback_used);
    assert!(!manifest.used_selections.is_empty());
    assert!(manifest
        .used_selections
        .iter()
        .all(|voice| voice.engine == "system"));
    assert_eq!(manifest.chapters.len(), 2);
    assert_eq!(manifest.chapters[0].source_index, 0);
    assert_eq!(manifest.chapters[1].source_index, 1);
    let mut archive =
        ZipArchive::new(fs::File::open(output.join(&manifest.archive)).unwrap()).unwrap();
    for chapter in &manifest.chapters {
        let audio = output.join(&chapter.filename);
        assert!(fs::metadata(&audio).unwrap().len() > 0);
        assert!(archive.by_name(&chapter.filename).unwrap().size() > 0);
        let receipt: serde_json::Value =
            serde_json::from_slice(&fs::read(audio.with_extension("mp3.complete.json")).unwrap())
                .unwrap();
        assert_eq!(receipt["provider"], "system");
        assert_eq!(receipt["fallback_used"], true);
        assert_eq!(
            receipt["used_selections"],
            serde_json::to_value(&manifest.used_selections).unwrap()
        );
        assert_eq!(receipt["audio_sha256"], cache::sha256_file(&audio).unwrap());
        let decoded = Command::new("ffmpeg")
            .args(["-nostdin", "-xerror", "-v", "error", "-i"])
            .arg(&audio)
            .args(["-f", "null", "-"])
            .output()
            .unwrap();
        assert!(
            decoded.status.success(),
            "{}",
            String::from_utf8_lossy(&decoded.stderr)
        );
    }
}

#[test]
fn explicit_no_secondary_remains_strict_in_embedded_conversion() {
    let root = tempfile::tempdir().unwrap();
    let mut preferences = TtsPreferences::app_default(true);
    preferences.secondary = None;
    let (session, output) = session(root.path(), "strict-native-disabled", preferences.clone());
    let error = session
        .convert()
        .expect_err("strict Faber cannot narrate an English book");
    assert!(error
        .to_string()
        .contains("Faber medium supports Portuguese"));
    assert_eq!(
        session.options().tts_preferences.as_ref(),
        Some(&preferences)
    );
    assert!(!output.join("manifest.json").exists());
    assert!(
        !output.exists()
            || fs::read_dir(output).unwrap().all(|entry| {
                entry
                    .unwrap()
                    .path()
                    .extension()
                    .is_none_or(|extension| extension != "mp3")
            })
    );
}
