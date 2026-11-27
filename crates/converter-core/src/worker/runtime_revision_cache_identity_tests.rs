//! Persisted audio identity must survive product version changes.
//!
//! The key literals below were computed from the code that still derived the
//! runtime revision from `CARGO_PKG_VERSION` (workspace version `0.1.0`), before
//! `NATIVE_RUNTIME_REVISION` replaced it. They must never change as a side
//! effect of a product version bump.
use super::*;
use crate::tts_preferences::{TtsPreferences, TtsSelection};
use crate::tts_session::{
    builtin_descriptors, ResolvedIdentity, SessionSelection, NATIVE_RUNTIME_REVISION,
};

fn native_revision(provider: &str, runtime: &str) -> String {
    builtin_descriptors()
        .into_iter()
        .find(|descriptor| descriptor.provider == provider && descriptor.runtime == runtime)
        .expect("built-in native descriptor")
        .revision
}

#[test]
fn native_runtime_revision_is_pinned_and_independent_of_the_package_version() {
    assert_eq!(NATIVE_RUNTIME_REVISION, "0.1.0");
    for (provider, runtime) in [
        ("piper", "piper"),
        ("edge", "edge-websocket"),
        ("system", "platform-speech"),
    ] {
        assert_eq!(native_revision(provider, runtime), NATIVE_RUNTIME_REVISION);
    }
    // The browser runtime keeps its own explicit revision.
    assert_eq!(
        native_revision("piper", "piper-web"),
        "piper-web/2;phonemize/1.0.0;ort/1.30.0"
    );
    // No cache-identity source may read the package version again.
    let package_version = ["env!(\"CARGO_PKG_", "VERSION\")"].concat();
    for source in [
        include_str!("../tts_session.rs"),
        include_str!("../tts_session/catalog.rs"),
        include_str!("native_tts_adapters.rs"),
        include_str!("segment_audio_cache.rs"),
        include_str!("tts_cache_identity.rs"),
    ] {
        assert!(!source.contains(&package_version));
    }
}

#[test]
fn segment_cache_key_is_byte_identical_to_the_package_version_era() {
    let identity = ResolvedIdentity {
        selection: SessionSelection::from_legacy(&TtsSelection::default()).unwrap(),
        runtime_revision: native_revision("piper", "piper"),
        artifacts: [
            ("config".to_owned(), "b".repeat(64)),
            ("model".to_owned(), "a".repeat(64)),
        ]
        .into(),
        reusable: true,
    };
    let key = crate::worker::segment_audio_cache::key(
        "book-source-sha256",
        "pt-BR",
        "Uma frase para a identidade do cache.",
        &identity,
        Default::default(),
    )
    .unwrap();
    assert_eq!(
        key,
        "7c8be552c68ead62c89c5914757fa5511fb75374be4e9425faa1d33f0a3f2f11"
    );
}

#[test]
fn chapter_request_key_is_byte_identical_to_the_package_version_era() {
    let temp = tempfile::tempdir().unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        std::iter::empty::<(String, String)>(),
        temp.path().to_path_buf(),
    ));
    fs::create_dir_all(&config.paths.piper_models_dir).unwrap();
    let model = config
        .paths
        .piper_models_dir
        .join("pt_BR-faber-medium.onnx");
    fs::write(&model, b"pinned synthetic model").unwrap();
    fs::write(model.with_extension("onnx.json"), b"{}").unwrap();
    let worker = ConversionWorker::new(config).unwrap();
    // Edge now needs the online consent, so the pinned Edge key is the consented
    // request's; the key function itself is unchanged.
    let edge = TtsPreferences {
        footnote_narration: Default::default(),
        silence_trim: Default::default(),
        policy_version: None,
        primary: TtsSelection {
            session: None,
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        },
        secondary: None,
        allow_online_fallback: true,
    };
    for (preferences, expected) in [
        (
            TtsPreferences::default(),
            "667f5663f111e74a7cf55eb4eaa25e1f0e59d3a51e8beb508767cc5713d2de30",
        ),
        (
            edge,
            "4ef5ef84cfc9722fd8a5bbec2f7dd9757e43e9b4f2c2011a46d9861394023a3f",
        ),
    ] {
        let mut request = preference_test_request();
        request.tts_preferences = Some(preferences.clone());
        let key = worker
            .typed_cache_request_key(&request, &preferences, Some("pt-BR"), "base-request-key")
            .unwrap();
        assert_eq!(key, expected, "{}", preferences.primary.engine);
    }
}
