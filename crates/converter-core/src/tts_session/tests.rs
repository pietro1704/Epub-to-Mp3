use super::*;
use crate::tts_preferences::{SegmentPolicy, TtsPreferences, TtsSelection};
use std::sync::Arc;

struct PcmProvider;
struct ConflictingProvider(&'static str);
impl TtsProvider for ConflictingProvider {
    fn descriptor(&self) -> ProviderDescriptor {
        PcmProvider.descriptor()
    }
    fn prepare(
        &self,
        selection: &SessionSelection,
        _: &str,
    ) -> Result<Box<dyn TtsSession>, TtsFailure> {
        let mut resolved = selection.clone();
        let mut revision = "r1".to_owned();
        match self.0 {
            "version" => resolved.version = 3,
            "voice" => resolved.voice = Some("undeclared-voice".into()),
            _ => revision = "unknown-runtime".into(),
        }
        Ok(Box::new(PcmSession(ResolvedIdentity {
            selection: resolved,
            runtime_revision: revision,
            artifacts: Default::default(),
            reusable: true,
        })))
    }
}

#[test]
fn registry_rejects_resolved_versions_revisions_and_undeclared_automatic_voices() {
    for conflict in ["version", "voice", "revision"] {
        let mut registry = TtsRegistry::default();
        registry
            .register(Arc::new(ConflictingProvider(conflict)))
            .unwrap();
        let mut requested = selection("voice-a");
        requested.voice = None;
        assert!(registry.prepare(&requested, "pt").is_err(), "{conflict}");
    }
}
struct PcmSession(ResolvedIdentity);
impl TtsProvider for PcmProvider {
    fn descriptor(&self) -> ProviderDescriptor {
        ProviderDescriptor {
            provider: "system".into(),
            runtime: "contract-pcm".into(),
            revision: "r1".into(),
            targets: vec!["test".into()],
            capabilities: TtsCapabilities {
                audio_formats: vec![AudioFormat::Pcm16 {
                    sample_rate: 24_000,
                    channels: 1,
                }],
                languages: vec!["pt".into()],
                voices: vec!["voice-a".into(), "voice-b".into()],
                voice_selection: true,
                configurable_options: Vec::new(),
                max_text_chars: 800,
                cancellation: CancellationCapability::AfterCall,
                streaming: false,
                audio_bytes: true,
                online: false,
            },
        }
    }
    fn prepare(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<Box<dyn TtsSession>, TtsFailure> {
        selection.validate(&self.descriptor(), language)?;
        Ok(Box::new(PcmSession(ResolvedIdentity {
            selection: selection.clone(),
            runtime_revision: "r1".into(),
            artifacts: BTreeMap::new(),
            reusable: true,
        })))
    }
}
impl TtsSession for PcmSession {
    fn identity(&self) -> &ResolvedIdentity {
        &self.0
    }
    fn synthesize(
        &mut self,
        _: &str,
        context: &SynthesisContext<'_>,
        sink: &mut AudioSink,
    ) -> Result<(), TtsFailure> {
        context.check()?;
        // Real PCM and the production encoder, independently decoded below.
        let frequency = if self.0.selection.voice.as_deref() == Some("voice-a") {
            220.0
        } else {
            440.0
        };
        let samples: Vec<u8> = (0..4800)
            .flat_map(|index| {
                let sample = ((index as f64 * frequency * std::f64::consts::TAU / 24_000.0).sin()
                    * 8000.0) as i16;
                sample.to_le_bytes()
            })
            .collect();
        sink.write(&samples)?;
        context.check()
    }
}
fn selection(voice: &str) -> SessionSelection {
    SessionSelection {
        version: 2,
        provider: "system".into(),
        runtime: "contract-pcm".into(),
        model_id: None,
        model_revision: None,
        voice: Some(voice.into()),
        options: BTreeMap::new(),
    }
}

#[test]
fn registry_prepares_two_voice_identities_and_encodes_real_audio() {
    let mut registry = TtsRegistry::default();
    registry.register(Arc::new(PcmProvider)).unwrap();
    assert!(registry.register(Arc::new(PcmProvider)).is_err());
    let mut outputs = Vec::new();
    let mut identities = Vec::new();
    for voice in ["voice-a", "voice-b"] {
        let mut session = registry.prepare(&selection(voice), "pt-BR").unwrap();
        let format = AudioFormat::Pcm16 {
            sample_rate: 24_000,
            channels: 1,
        };
        let mut sink = AudioSink::new(format, MAX_SEGMENT_BYTES);
        session
            .synthesize(
                "Olá",
                &SynthesisContext {
                    language: "pt-BR",
                    cancelled: &|| false,
                    replaced: &|| false,
                },
                &mut sink,
            )
            .unwrap();
        let mp3 = sink.into_mp3().unwrap();
        crate::pcm::validate_mp3(&mp3).unwrap();
        #[cfg(not(target_arch = "wasm32"))]
        {
            use symphonia::core::{
                formats::FormatOptions,
                io::{MediaSourceStream, MediaSourceStreamOptions},
                meta::MetadataOptions,
                probe::Hint,
            };
            let stream = MediaSourceStream::new(
                Box::new(std::io::Cursor::new(mp3.clone())),
                MediaSourceStreamOptions::default(),
            );
            let mut hint = Hint::new();
            hint.with_extension("mp3");
            let mut probed = symphonia::default::get_probe()
                .format(
                    &hint,
                    stream,
                    &FormatOptions::default(),
                    &MetadataOptions::default(),
                )
                .unwrap();
            let track = probed.format.default_track().unwrap();
            let mut decoder = symphonia::default::get_codecs()
                .make(&track.codec_params, &Default::default())
                .unwrap();
            let packet = probed.format.next_packet().unwrap();
            assert!(decoder.decode(&packet).unwrap().frames() > 0);
        }
        identities.push(
            cache_material(
                "source:chapter:range:text-hash",
                "text-v1",
                session.identity(),
                &AudioFormat::Mp3,
            )
            .unwrap(),
        );
        outputs.push(mp3);
    }
    assert_ne!(identities[0], identities[1]);
    assert_ne!(outputs[0], outputs[1]);
    let restored: ResolvedIdentity = serde_json::from_str(
        &serde_json::to_string(
            &registry
                .prepare(&selection("voice-a"), "pt")
                .unwrap()
                .identity(),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        identities[0],
        cache_material(
            "source:chapter:range:text-hash",
            "text-v1",
            &restored,
            &AudioFormat::Mp3
        )
        .unwrap()
    );
}

#[test]
fn rejects_unavailable_runtime_revision_unknown_voice_and_unbounded_or_mislabeled_audio() {
    let mut registry = TtsRegistry::default();
    registry.register(Arc::new(PcmProvider)).unwrap();
    let mut request = selection("voice-a");
    request.runtime = "missing".into();
    assert!(registry.prepare(&request, "pt").is_err());
    request = selection("missing");
    assert!(registry.prepare(&request, "pt").is_err());
    request = selection("voice-a");
    request.version = 99;
    assert!(registry.prepare(&request, "pt").is_err());
    let mut sink = AudioSink::new(AudioFormat::Mp3, 4);
    assert!(sink.write(&[0; 5]).is_err());
    assert!(normalize_audio(&AudioFormat::Mp3, b"RIFFxxxxWAVE").is_err());
    assert!(normalize_audio(&AudioFormat::WavPcm16, b"not a WAV").is_err());
    assert!(normalize_audio(
        &AudioFormat::Pcm16 {
            sample_rate: 24_000,
            channels: 2
        },
        &[0; 100]
    )
    .is_err());
    assert!(encode_pcm_f32(&[f32::NAN], 24_000).is_err());
    assert!(encode_pcm_f32(&[f32::INFINITY], 24_000).is_err());
}

#[test]
fn cancellation_and_replacement_never_produce_fallback_or_commit_policy() {
    let preferences = TtsPreferences::app_default(true);
    let policy = SegmentPolicy::default();
    let before = serde_json::to_string(&policy).unwrap();
    for kind in [FailureKind::Cancelled, FailureKind::Replaced] {
        let mut attempt = RecoveryAttempt::new(&policy, &preferences, true).unwrap();
        assert!(attempt.failed(&TtsFailure::new(kind, "terminal")).is_err());
        assert!(!attempt.fallback_used());
        assert_eq!(before, serde_json::to_string(&policy).unwrap());
    }
    let provider = PcmProvider;
    let mut session = provider.prepare(&selection("voice-a"), "pt").unwrap();
    for (cancelled, replaced, kind) in [
        (true, false, FailureKind::Cancelled),
        (false, true, FailureKind::Replaced),
    ] {
        let mut sink = AudioSink::new(AudioFormat::Mp3, 100);
        assert_eq!(
            session
                .synthesize(
                    "text",
                    &SynthesisContext {
                        language: "pt",
                        cancelled: &|| cancelled,
                        replaced: &|| replaced
                    },
                    &mut sink
                )
                .unwrap_err()
                .kind,
            kind
        );
    }
}

#[test]
fn native_and_external_sessions_share_strict_recovery_and_restart_policy() {
    for installed_system in [false, true] {
        let preferences = TtsPreferences {
            primary: TtsSelection {
                session: None,
                engine: "edge".into(),
                model_id: None,
                voice: None,
            },
            secondary: Some(TtsSelection {
                engine: "piper".into(),
                ..TtsSelection::default()
            }),
            ..TtsPreferences::default()
        };
        let mut policy = SegmentPolicy::default();
        for index in 0..3 {
            let mut attempt =
                RecoveryAttempt::new(&policy, &preferences, installed_system).unwrap();
            let result = attempt.failed(&TtsFailure::new(FailureKind::Synthesis, "failed"));
            if index == 2 {
                assert!(result.is_err());
                break;
            }
            result.unwrap();
            assert_eq!(attempt.selection().engine, "piper");
            policy =
                serde_json::from_str(&serde_json::to_string(&attempt.accepted()).unwrap()).unwrap();
        }
    }
    let preferences = TtsPreferences::app_default(true);
    let mut attempt = RecoveryAttempt::new(&SegmentPolicy::default(), &preferences, true).unwrap();
    attempt
        .failed(&TtsFailure::new(FailureKind::Unavailable, "missing model"))
        .unwrap();
    assert_eq!(attempt.selection().engine, "system");
    assert_eq!(
        preferences.primary.model_id.as_deref(),
        Some("pt_BR-faber-medium")
    );
}

#[test]
fn cache_separates_runtime_artifacts_revision_options_range_and_format() {
    let mut identity = ResolvedIdentity {
        selection: selection("voice-a"),
        runtime_revision: "r1".into(),
        artifacts: BTreeMap::from([("model".into(), "sha-a".into())]),
        reusable: true,
    };
    let original = cache_material("range-a", "text-v1", &identity, &AudioFormat::Mp3).unwrap();
    for mutation in ["runtime", "artifact", "model", "options"] {
        let mut changed = identity.clone();
        match mutation {
            "runtime" => changed.runtime_revision = "r2".into(),
            "artifact" => {
                changed.artifacts.insert("model".into(), "sha-b".into());
            }
            "model" => changed.selection.model_revision = Some("rev-b".into()),
            _ => {
                changed
                    .selection
                    .options
                    .insert("speed".into(), "1.2".into());
            }
        }
        assert_ne!(
            original,
            cache_material("range-a", "text-v1", &changed, &AudioFormat::Mp3).unwrap()
        );
    }
    assert_ne!(
        original,
        cache_material("range-b", "text-v1", &identity, &AudioFormat::Mp3).unwrap()
    );
    assert_ne!(
        original,
        cache_material("range-a", "text-v2", &identity, &AudioFormat::Mp3).unwrap()
    );
    assert_ne!(
        original,
        cache_material("range-a", "text-v1", &identity, &AudioFormat::WavPcm16).unwrap()
    );
    identity.reusable = false;
    assert!(cache_material("range-a", "text-v1", &identity, &AudioFormat::Mp3).is_err());
}

#[test]
fn prepared_session_owns_its_adapter_state_after_registry_is_dropped() {
    let mut session = {
        let mut registry = TtsRegistry::default();
        registry.register(Arc::new(PcmProvider)).unwrap();
        registry.prepare(&selection("voice-a"), "pt").unwrap()
    };
    let mut sink = AudioSink::new(
        AudioFormat::Pcm16 {
            sample_rate: 24_000,
            channels: 1,
        },
        MAX_SEGMENT_BYTES,
    );
    session
        .synthesize(
            "Olá",
            &SynthesisContext {
                language: "pt",
                cancelled: &|| false,
                replaced: &|| false,
            },
            &mut sink,
        )
        .unwrap();
    crate::pcm::validate_mp3(&sink.into_mp3().unwrap()).unwrap();
}

#[test]
fn legacy_and_versioned_wrappers_cannot_select_the_same_secondary_voice() {
    let mut preferences = TtsPreferences::default();
    let mut secondary = preferences.primary.clone();
    secondary.session = Some(SessionSelection::from_legacy(&secondary).unwrap());
    preferences.secondary = Some(secondary);
    assert!(preferences.validate(None).unwrap_err().contains("differ"));
}
