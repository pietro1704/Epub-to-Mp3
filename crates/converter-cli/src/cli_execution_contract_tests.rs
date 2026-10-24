use std::{fs, path::PathBuf};

use super::cli_arguments::parse_args;
use super::cli_environment::{home_dir, packaged_data_root};
use super::conversion_command::conversion_config;
use super::output_reporting::verify_output;
use super::CliOptions;

#[test]
fn conventional_help_never_opens_inputs_or_starts_conversion() {
    for arguments in [
        vec!["--help"],
        vec!["-h"],
        vec!["convert", "--help"],
        vec!["/missing/input.epub", "--help"],
    ] {
        assert_eq!(
            super::run_cli_command(arguments.into_iter().map(str::to_owned).collect()).unwrap(),
            0
        );
    }
}

#[test]
fn help_does_not_hide_malformed_options_or_consume_literal_values() {
    assert!(super::run_cli_command(vec!["--unknown".into(), "--help".into()]).is_err());
    assert!(super::run_cli_command(vec!["--chapter".into()]).is_err());
    let options = parse_args(&["--voice".into(), "--help".into()]).unwrap();
    assert!(!options.help);
    assert_eq!(options.voice.as_deref(), Some("--help"));
}

#[test]
fn a_packaged_cli_uses_user_data_and_preserves_explicit_directory_overrides() {
    let package =
        std::env::temp_dir().join(format!("tts-cli-package-paths-{}", std::process::id()));
    fs::create_dir_all(package.join("bin")).unwrap();
    let executable = package.join("bin").join("converter-cli");
    let home = package.join("user-home");
    assert!(packaged_data_root(&executable, Some(&home), None).is_none());
    fs::write(
        package.join("package.json"),
        r#"{"runtime":"native Rust/Piper"}"#,
    )
    .unwrap();
    let persistent = packaged_data_root(&executable, Some(&home), None).unwrap();
    assert!(persistent.starts_with(&home));
    let cache = package.join("chosen-cache");
    let output = package.join("chosen-output");
    let paths = converter_core::paths::resolve_paths_from(
        [
            ("PERSISTENT_ROOT", persistent.clone()),
            ("CACHE_DIR", cache.clone()),
            ("OUTPUT_DIR", output.clone()),
        ],
        package.join("missing-original-checkout"),
    );
    assert_eq!(paths.persistent_root, persistent);
    assert_eq!(paths.cache_dir, cache);
    assert_eq!(paths.output_dir, output);
    fs::remove_dir_all(package).unwrap();
}

#[test]
fn output_directory_option_overrides_only_the_output_path() {
    let options = parse_args(&[
        "convert".into(),
        "book.epub".into(),
        "--output-dir".into(),
        "chosen output".into(),
    ])
    .unwrap();
    let original = converter_core::config::AppConfig::from_env();
    let configured = conversion_config(&options);
    assert_eq!(configured.paths.output_dir, PathBuf::from("chosen output"));
    assert_eq!(configured.paths.cache_dir, original.paths.cache_dir);
    assert_eq!(configured.paths.jobs_dir, original.paths.jobs_dir);
}

#[test]
fn output_directory_expands_the_home_prefix() {
    let options = CliOptions {
        output_dir: Some("~/audiobooks".into()),
        ..Default::default()
    };
    assert_eq!(
        conversion_config(&options).paths.output_dir,
        home_dir().join("audiobooks")
    );
}

#[test]
fn omitted_output_option_preserves_the_runtime_default() {
    assert_eq!(
        conversion_config(&CliOptions::default()),
        converter_core::config::AppConfig::from_env()
    );
}

#[test]
fn cli_sources_only_the_embedded_core_api() {
    let source = concat!(
        include_str!("main.rs"),
        include_str!("cli_environment.rs"),
        include_str!("tts_preferences_command.rs"),
        include_str!("model_commands.rs"),
        include_str!("conversion_command.rs"),
        include_str!("cli_arguments.rs"),
        include_str!("cli_book_inputs.rs"),
        include_str!("cli_cache_commands.rs"),
        include_str!("output_reporting.rs"),
    );
    assert!(source.contains("EmbeddedConversionSession"));
    assert!(!source
        .lines()
        .any(|line| line.trim_start().starts_with("use converter_server")));
    let forbidden_client = ["re", "qwest"].concat();
    assert!(!source.contains(&forbidden_client));
    let forbidden_http = ["http", "://"].concat();
    assert!(!source.contains(&forbidden_http));
}

#[test]
fn verification_rejects_missing_chapter_audio() {
    let root = std::env::temp_dir().join(format!("converter-verify-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("temporary directory should be created");
    let manifest = converter_core::worker::OutputManifest {
        synthesis_sessions: Vec::new(),
        source_chapters_total: None,
        tts_preferences: None,
        used_selections: Vec::new(),
        tts_policy_state: Default::default(),
        fallback_used: false,
        job_id: "test".into(),
        title: "Book".into(),
        author: "Author".into(),
        chapters: vec![converter_core::audio::ChapterMetadata {
            text_offset: 0,
            index: 1,
            source_index: 0,
            title: "Chapter 1".into(),
            filename: "0001-Chapter_1.mp3".into(),
            text_chars: 10,
        }],
        archive: "archive.zip".into(),
        cover: None,
    };
    let error = verify_output(&root, &manifest).expect_err("missing audio must fail");
    assert!(error.contains("verification failed"));
    let _ = fs::remove_dir_all(root);
}
