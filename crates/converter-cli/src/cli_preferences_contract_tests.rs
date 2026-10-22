use std::fs;

use super::cli_arguments::parse_args;
use super::tts_preferences_command::{
    effective_preferences, parse_captured_preferences, preference_path,
    preferences_with_legacy_engine, saved_preferences,
};

#[test]
fn only_explicit_legacy_engine_overrides_the_faber_default() {
    use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
    let initial = TtsPreferences::default();
    assert_eq!(
        preferences_with_legacy_engine(initial.clone(), None).unwrap(),
        initial
    );
    assert_eq!(
        preferences_with_legacy_engine(initial.clone(), Some("auto")).unwrap(),
        initial
    );
    let explicit = preferences_with_legacy_engine(initial.clone(), Some(" EDGE ")).unwrap();
    assert_eq!(explicit.primary.engine, "edge");
    assert!(explicit.primary.model_id.is_none());
    assert!(explicit.secondary.is_none());
    let saved = TtsPreferences {
        policy_version: None,
        primary: TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        },
        secondary: None,
        allow_online_fallback: false,
    };
    assert_eq!(
        preferences_with_legacy_engine(saved.clone(), Some("edge")).unwrap(),
        saved
    );
    assert_eq!(
        preferences_with_legacy_engine(saved, Some("piper"))
            .unwrap()
            .primary,
        TtsSelection::default()
    );
    assert!(preferences_with_legacy_engine(initial, Some("invented")).is_err());
}

#[test]
fn manual_override_is_strict_and_model_reaches_effective_preferences() {
    use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
    let root = std::env::temp_dir().join(format!("tts-cli-preferences-{}", std::process::id()));
    let paths = converter_core::paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.clone(),
    );
    let config = converter_core::config::AppConfig::from_paths(paths);
    let saved = TtsPreferences {
        policy_version: None,
        primary: TtsSelection::default(),
        secondary: Some(TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        }),
        allow_online_fallback: true,
    };
    converter_core::cache::atomic_write_json(preference_path(&config), &saved).unwrap();
    let raw = [
        "convert",
        "book.epub",
        "--engine",
        "piper",
        "--model",
        "pt_BR-faber-medium",
    ]
    .map(str::to_owned);
    let effective = effective_preferences(&config, &parse_args(&raw).unwrap(), &raw).unwrap();
    assert_eq!(
        effective.primary.model_id.as_deref(),
        Some("pt_BR-faber-medium")
    );
    assert!(effective.secondary.is_none());
    assert_eq!(saved_preferences(&config).unwrap(), saved);
    let inherited = ["convert", "book.epub"].map(str::to_owned);
    assert_eq!(
        effective_preferences(&config, &parse_args(&inherited).unwrap(), &inherited).unwrap(),
        saved
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn explicit_secondary_options_are_preserved_for_conversion() {
    let args = [
        "convert",
        "book.epub",
        "--engine",
        "piper",
        "--model",
        "pt_BR-faber-medium",
        "--fallback-engine",
        "edge",
        "--fallback-voice",
        "pt-BR-FranciscaNeural",
        "--allow-online-fallback",
    ]
    .map(str::to_owned);
    let options = parse_args(&args).unwrap();
    assert_eq!(options.model.as_deref(), Some("pt_BR-faber-medium"));
    assert_eq!(options.fallback_engine, "edge");
    assert_eq!(
        options.fallback_voice.as_deref(),
        Some("pt-BR-FranciscaNeural")
    );
    assert_eq!(options.allow_online_fallback, Some(true));
}

#[test]
fn online_fallback_flags_capture_consent_and_reject_conflicts() {
    let inherited = ["convert", "book.epub"].map(str::to_owned);
    assert_eq!(parse_args(&inherited).unwrap().allow_online_fallback, None);
    for (flag, expected) in [
        ("--allow-online-fallback", true),
        ("--no-online-fallback", false),
    ] {
        let args = ["convert", "book.epub", flag, flag].map(str::to_owned);
        assert_eq!(
            parse_args(&args).unwrap().allow_online_fallback,
            Some(expected)
        );
    }
    for flags in [
        ["--allow-online-fallback", "--no-online-fallback"],
        ["--no-online-fallback", "--allow-online-fallback"],
    ] {
        let args = ["convert", "book.epub", flags[0], flags[1]].map(str::to_owned);
        assert!(parse_args(&args)
            .unwrap_err()
            .contains("mutually exclusive"));
    }
}

#[test]
fn explicit_consent_revocation_overrides_saved_consent_without_mutating_it() {
    use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
    let root = std::env::temp_dir().join(format!("tts-cli-revoke-{}", std::process::id()));
    let paths = converter_core::paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.clone(),
    );
    let config = converter_core::config::AppConfig::from_paths(paths);
    let saved = TtsPreferences {
        policy_version: None,
        primary: TtsSelection::default(),
        secondary: Some(TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        }),
        allow_online_fallback: true,
    };
    converter_core::cache::atomic_write_json(preference_path(&config), &saved).unwrap();
    let stored = fs::read(preference_path(&config)).unwrap();
    let inherited = [
        "convert",
        "book.epub",
        "--engine",
        "piper",
        "--use-secondary",
    ]
    .map(str::to_owned);
    assert_eq!(
        effective_preferences(&config, &parse_args(&inherited).unwrap(), &inherited).unwrap(),
        saved
    );

    let denied = [
        "convert",
        "book.epub",
        "--engine",
        "piper",
        "--fallback-engine",
        "none",
        "--no-online-fallback",
    ]
    .map(str::to_owned);
    let effective = effective_preferences(&config, &parse_args(&denied).unwrap(), &denied).unwrap();
    assert!(!effective.allow_online_fallback);
    assert!(effective.secondary.is_none());
    assert_eq!(effective.primary, saved.primary);

    let invalid = [
        "convert",
        "book.epub",
        "--engine",
        "piper",
        "--use-secondary",
        "--no-online-fallback",
    ]
    .map(str::to_owned);
    assert!(effective_preferences(&config, &parse_args(&invalid).unwrap(), &invalid).is_err());
    assert_eq!(saved_preferences(&config).unwrap(), saved);
    assert_eq!(fs::read(preference_path(&config)).unwrap(), stored);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn an_edge_secondary_can_be_enabled_only_with_explicit_consent() {
    let root = std::env::temp_dir().join(format!("tts-cli-grant-{}", std::process::id()));
    let paths = converter_core::paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.clone(),
    );
    let config = converter_core::config::AppConfig::from_paths(paths);
    let saved = converter_core::tts_preferences::TtsPreferences::default();
    converter_core::cache::atomic_write_json(preference_path(&config), &saved).unwrap();
    let stored = fs::read(preference_path(&config)).unwrap();
    let mut args = [
        "convert",
        "book.epub",
        "--engine",
        "piper",
        "--fallback-engine",
        "edge",
    ]
    .map(str::to_owned)
    .to_vec();
    assert!(effective_preferences(&config, &parse_args(&args).unwrap(), &args).is_err());
    args.push("--allow-online-fallback".into());
    let effective = effective_preferences(&config, &parse_args(&args).unwrap(), &args).unwrap();
    assert!(effective.allow_online_fallback);
    assert_eq!(effective.secondary.unwrap().engine, "edge");
    assert_eq!(saved_preferences(&config).unwrap(), saved);
    assert_eq!(fs::read(preference_path(&config)).unwrap(), stored);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn captured_preferences_replace_saved_voice_and_consent_without_writing_the_profile() {
    use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
    let root = std::env::temp_dir().join(format!("tts-cli-snapshot-{}", std::process::id()));
    let paths = converter_core::paths::resolve_paths_from(
        [("PERSISTENT_ROOT", root.to_string_lossy().into_owned())],
        root.clone(),
    );
    let config = converter_core::config::AppConfig::from_paths(paths);
    let saved = TtsPreferences {
        policy_version: None,
        primary: TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        },
        secondary: None,
        allow_online_fallback: true,
    };
    converter_core::cache::atomic_write_json(preference_path(&config), &saved).unwrap();
    let stored = fs::read(preference_path(&config)).unwrap();
    let captured = TtsPreferences {
        policy_version: None,
        primary: TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: None,
        },
        secondary: None,
        allow_online_fallback: false,
    };
    let json = serde_json::to_string(&captured).unwrap();
    let args = vec![
        "convert".into(),
        "book.epub".into(),
        "--tts-preferences-json".into(),
        json,
        "--chapter".into(),
        "1-2".into(),
        "--no-parallel".into(),
    ];
    let options = parse_args(&args).unwrap();
    assert_eq!(options.chapters, vec!["1-2"]);
    assert!(options.no_parallel);
    assert_eq!(
        effective_preferences(&config, &options, &args).unwrap(),
        captured
    );
    assert_eq!(saved_preferences(&config).unwrap(), saved);
    assert_eq!(fs::read(preference_path(&config)).unwrap(), stored);

    fs::write(preference_path(&config), b"invalid saved preferences").unwrap();
    assert!(saved_preferences(&config).is_err());
    assert_eq!(
        effective_preferences(&config, &options, &args).unwrap(),
        captured
    );
    assert_eq!(
        fs::read(preference_path(&config)).unwrap(),
        b"invalid saved preferences"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn captured_preferences_reject_invalid_schema_policy_and_duplicate_arguments() {
    use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
    let approved = TtsPreferences {
        policy_version: None,
        primary: TtsSelection::default(),
        secondary: Some(TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        }),
        allow_online_fallback: true,
    };
    assert_eq!(
        parse_captured_preferences(&serde_json::to_string(&approved).unwrap()).unwrap(),
        approved
    );
    let valid =
        serde_json::to_string(&converter_core::tts_preferences::TtsPreferences::default()).unwrap();
    for json in [
        "{",
        r#"{"primary":{"engine":"edge"},"secondary":null}"#,
        r#"{"primary":{"engine":"edge"},"allow_online_fallback":false,"unknown":0}"#,
        r#"{"primary":{"engine":"edge","unknown":0},"allow_online_fallback":false}"#,
        r#"{"primary":{"engine":"edge","voice":null,"voice":"other"},"allow_online_fallback":false}"#,
        r#"{"primary":{"engine":"edge"},"allow_online_fallback":false,"allow_online_fallback":true}"#,
        r#"{"primary":{"engine":"piper","model_id":"pt_BR-faber-medium"},"secondary":{"engine":"edge"},"allow_online_fallback":false}"#,
    ] {
        let args = ["convert", "book.epub", "--tts-preferences-json", json].map(str::to_owned);
        assert!(parse_args(&args).is_err(), "Unexpectedly accepted: {json}");
    }
    let duplicate = [
        "convert",
        "book.epub",
        "--tts-preferences-json",
        &valid,
        "--tts-preferences-json",
        &valid,
    ]
    .map(str::to_owned);
    assert!(parse_args(&duplicate).unwrap_err().contains("only once"));
    let missing = ["convert", "book.epub", "--tts-preferences-json"].map(str::to_owned);
    assert!(parse_args(&missing).is_err());
}

#[test]
fn captured_preferences_are_exclusive_of_tts_flags_but_not_literal_flag_values() {
    let json =
        serde_json::to_string(&converter_core::tts_preferences::TtsPreferences::default()).unwrap();
    for legacy in [
        vec!["--engine", "edge"],
        vec!["--voice", "pt-BR-FranciscaNeural"],
        vec!["--model", "pt_BR-faber-medium"],
        vec!["--fallback-engine", "none"],
        vec!["--fallback-model", "pt_BR-faber-medium"],
        vec!["--fallback-voice", "pt-BR-FranciscaNeural"],
        vec!["--engine-chain-fallback"],
        vec!["--allow-online-fallback"],
        vec!["--no-online-fallback"],
        vec!["--use-secondary"],
    ] {
        for snapshot_first in [true, false] {
            let mut args = vec!["convert".to_owned(), "book.epub".to_owned()];
            let snapshot = ["--tts-preferences-json", json.as_str()];
            let (first, second): (&[&str], &[&str]) = if snapshot_first {
                (&snapshot, &legacy)
            } else {
                (&legacy, &snapshot)
            };
            args.extend(first.iter().chain(second).map(|value| (*value).to_owned()));
            assert!(
                parse_args(&args).is_err(),
                "Accepted mixed TTS flags: {args:?}"
            );
        }
    }
    let literal = [
        "convert",
        "book.epub",
        "--tts-preferences-json",
        &json,
        "--output-dir",
        "--engine",
    ]
    .map(str::to_owned);
    assert_eq!(
        parse_args(&literal).unwrap().output_dir.as_deref(),
        Some("--engine")
    );
}
