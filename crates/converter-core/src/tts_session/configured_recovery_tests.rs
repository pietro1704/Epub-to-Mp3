use super::{FailureKind, RecoveryAttempt, TtsFailure};
use crate::tts_preferences::{SegmentPolicy, TtsPreferences, TtsSelection};

fn configured_pair() -> TtsPreferences {
    TtsPreferences {
        policy_version: Some(3),
        secondary: Some(TtsSelection {
            model_id: Some("en_US-ljspeech-high".into()),
            ..TtsSelection::default()
        }),
        ..TtsPreferences::default()
    }
}

#[test]
fn configured_only_policy_roundtrips_and_separates_cached_system_audio() {
    let preferences = configured_pair();
    preferences.validate(Some("en-US")).unwrap();
    let restored: TtsPreferences =
        serde_json::from_str(&serde_json::to_string(&preferences).unwrap()).unwrap();
    assert_eq!(restored, preferences);
    assert!(restored.continues_native());
    assert!(!restored.permits_automatic_system_voice());
    let mut automatic = preferences.clone();
    automatic.policy_version = Some(2);
    assert_ne!(
        automatic.cache_fingerprint(Some("en-US"), &[]),
        preferences.cache_fingerprint(Some("en-US"), &[])
    );
    assert!(TtsPreferences::app_default(true).permits_automatic_system_voice());
}

#[test]
fn configured_secondary_continues_and_retries_primary_without_inventing_system_voice() {
    let preferences = configured_pair();
    let original = preferences.clone();
    let mut policy = SegmentPolicy::default();
    let mut primary_attempts = 0;
    for _ in 0..8 {
        let mut attempt = RecoveryAttempt::new(&policy, &preferences, true).unwrap();
        if attempt.selection() == &preferences.primary {
            primary_attempts += 1;
            attempt
                .failed(&TtsFailure::new(
                    FailureKind::Unavailable,
                    "primary unavailable",
                ))
                .unwrap();
        }
        assert_eq!(Some(attempt.selection()), preferences.secondary.as_ref());
        assert!(attempt.fallback_used());
        policy =
            serde_json::from_str(&serde_json::to_string(&attempt.accepted()).unwrap()).unwrap();
    }
    assert!(
        (2..8).contains(&primary_attempts),
        "Recovery must remain bounded and retry the primary"
    );
    assert_eq!(preferences, original);
    let mut recovered =
        RecoveryAttempt::new(&SegmentPolicy::default(), &preferences, true).unwrap();
    assert_eq!(recovered.selection(), &preferences.primary);
    assert!(!recovered.fallback_used());
    recovered = RecoveryAttempt::new(&recovered.accepted(), &preferences, true).unwrap();
    assert_eq!(recovered.selection(), &preferences.primary);
}

#[test]
fn exhaustion_or_missing_secondary_never_uses_installed_system_voice() {
    for installed_system in [false, true] {
        for has_secondary in [false, true] {
            let mut preferences = configured_pair();
            if !has_secondary {
                preferences.secondary = None;
            }
            let mut attempt =
                RecoveryAttempt::new(&SegmentPolicy::default(), &preferences, installed_system)
                    .unwrap();
            let failure = TtsFailure::new(FailureKind::Unavailable, "selected voice unavailable");
            if has_secondary {
                attempt.failed(&failure).unwrap();
            }
            assert_eq!(
                attempt.failed(&failure).unwrap_err().kind,
                FailureKind::Unavailable
            );
            assert_ne!(attempt.selection().engine, "system");
        }
    }
}

#[test]
fn configured_only_policy_preserves_explicit_system_selection() {
    let mut preferences = configured_pair();
    preferences.secondary = Some(TtsSelection {
        engine: "system".into(),
        session: None,
        model_id: None,
        voice: None,
    });
    let mut attempt = RecoveryAttempt::new(&SegmentPolicy::default(), &preferences, true).unwrap();
    attempt
        .failed(&TtsFailure::new(
            FailureKind::Unavailable,
            "missing primary",
        ))
        .unwrap();
    assert_eq!(Some(attempt.selection()), preferences.secondary.as_ref());
}

#[test]
fn cancellation_or_replacement_never_selects_another_voice_or_commits_counters() {
    let preferences = configured_pair();
    let policy = SegmentPolicy::default();
    let original = serde_json::to_string(&policy).unwrap();
    for kind in [FailureKind::Cancelled, FailureKind::Replaced] {
        let mut attempt = RecoveryAttempt::new(&policy, &preferences, true).unwrap();
        assert_eq!(
            attempt
                .failed(&TtsFailure::new(kind, "terminal"))
                .unwrap_err()
                .kind,
            kind
        );
        assert_eq!(attempt.selection(), &preferences.primary);
        assert!(!attempt.fallback_used());
        assert_eq!(
            serde_json::to_string(&attempt.accepted()).unwrap(),
            original
        );
        assert_eq!(serde_json::to_string(&policy).unwrap(), original);
    }
}
