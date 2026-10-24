use super::*;
use crate::tts_session::{ListeningPosition, PlaybackFeedback};

#[test]
fn listening_seek_during_provider_preparation_never_synthesizes_or_streams_old_text() {
    use crate::tts_session::*;
    struct Provider {
        control: crate::conversion_control::ConversionControl,
        offset: usize,
        texts: Arc<Mutex<Vec<String>>>,
    }
    struct Session {
        identity: ResolvedIdentity,
        texts: Arc<Mutex<Vec<String>>>,
    }
    impl TtsProvider for Provider {
        fn descriptor(&self) -> ProviderDescriptor {
            let mut descriptor = builtin_descriptors()[2].clone();
            descriptor.provider = "prepare-fixture".into();
            descriptor.runtime = "wav-fixture".into();
            descriptor.revision = "test-1".into();
            descriptor
        }
        fn prepare(
            &self,
            selection: &SessionSelection,
            _: &str,
        ) -> Result<Box<dyn TtsSession>, TtsFailure> {
            self.control
                .set_listening_position(ListeningPosition {
                    version: 2,
                    chapter_index: 0,
                    text_offset: self.offset,
                })
                .unwrap();
            Ok(Box::new(Session {
                identity: ResolvedIdentity {
                    selection: selection.clone(),
                    runtime_revision: "test-1".into(),
                    artifacts: Default::default(),
                    reusable: true,
                },
                texts: self.texts.clone(),
            }))
        }
    }
    impl TtsSession for Session {
        fn identity(&self) -> &ResolvedIdentity {
            &self.identity
        }
        fn synthesize(
            &mut self,
            text: &str,
            context: &SynthesisContext<'_>,
            sink: &mut AudioSink,
        ) -> Result<(), TtsFailure> {
            context.check()?;
            self.texts.lock().unwrap().push(text.into());
            sink.write(&test_system_wav())
        }
    }
    let temporary = tempfile::tempdir().unwrap();
    let input = temporary.path().join("seek.epub");
    platform_test_book_with_text(&input, "Retired text. Fresh selected sentence.");
    let book =
        crate::epub::parse_epub(std::io::BufReader::new(fs::File::open(&input).unwrap())).unwrap();
    let source = &book.chapters[0].text;
    let offset = source[..source.find("Fresh").unwrap()].chars().count();
    let control = crate::conversion_control::ConversionControl::new();
    control
        .set_listening_position(ListeningPosition {
            version: 2,
            chapter_index: 0,
            text_offset: 0,
        })
        .unwrap();
    let texts = Arc::new(Mutex::new(Vec::new()));
    let mut registry = TtsRegistry::default();
    registry
        .register(Arc::new(Provider {
            control: control.clone(),
            offset,
            texts: texts.clone(),
        }))
        .unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temporary.path().to_owned(),
    ));
    let chunks = Arc::new(AtomicUsize::new(0));
    let published = chunks.clone();
    let worker = ConversionWorker::new(config)
        .unwrap()
        .with_control(control)
        .with_tts_registry(registry)
        .with_streaming_chunks(Arc::new(move |_, _, _| {
            published.fetch_add(1, Ordering::AcqRel);
            true
        }));
    let mut request = preference_test_request();
    request.input = input;
    request.job_id = "seek-during-prepare".into();
    request.tts_preferences = Some(crate::tts_preferences::TtsPreferences {
        primary: crate::tts_preferences::TtsSelection {
            engine: "prepare-fixture".into(),
            model_id: None,
            voice: None,
            session: Some(SessionSelection {
                version: 2,
                provider: "prepare-fixture".into(),
                runtime: "wav-fixture".into(),
                model_id: None,
                model_revision: None,
                voice: None,
                options: Default::default(),
            }),
        },
        ..Default::default()
    });
    let manifest = worker.run(request).unwrap();
    assert_eq!(*texts.lock().unwrap(), vec!["Fresh selected sentence."]);
    assert_eq!(chunks.load(Ordering::Acquire), 1);
    assert_eq!(manifest.chapters[0].text_offset, offset);
}

#[test]
fn listening_publication_lease_preserves_previous_artifacts_on_seek_and_cancel() {
    let temporary = tempfile::tempdir().unwrap();
    let output = temporary.path().join("chapter.mp3");
    let old = crate::platform_tts::encode_wav(&test_system_wav()).unwrap();
    let new = crate::platform_tts::encode_wav(&test_system_wav_at_rate(24000)).unwrap();
    ensure_chapter_audio(&output, "old", |pending| {
        fs::write(pending, &old)?;
        Ok(())
    })
    .unwrap();
    let old_receipt = fs::read(chapter_audio_receipt_path(&output)).unwrap();
    let control = crate::conversion_control::ConversionControl::new();
    control
        .set_listening_position(ListeningPosition {
            version: 2,
            chapter_index: 0,
            text_offset: 0,
        })
        .unwrap();
    let stale = super::super::chapter_audio_receipt::ensure_chapter_audio_with_control(
        &output,
        "new",
        true,
        Some(&control),
        Some(0),
        Some(0),
        |pending| {
            fs::write(pending, &new)?;
            control
                .set_listening_position(ListeningPosition {
                    version: 2,
                    chapter_index: 0,
                    text_offset: 1,
                })
                .unwrap();
            Ok(())
        },
    );
    assert!(matches!(stale, Err(WorkerError::PlaybackWindowChanged)));
    assert_eq!(fs::read(&output).unwrap(), old);
    assert_eq!(
        fs::read(chapter_audio_receipt_path(&output)).unwrap(),
        old_receipt
    );
    super::super::chapter_audio_receipt::ensure_chapter_audio_with_control(
        &output,
        "new",
        true,
        Some(&control),
        Some(1),
        Some(0),
        |pending| {
            fs::write(pending, &new)?;
            Ok(())
        },
    )
    .unwrap();
    assert!(chapter_audio_is_complete(&output, "new"));
    let receipt = fs::read(chapter_audio_receipt_path(&output)).unwrap();
    let cancelled = super::super::chapter_audio_receipt::ensure_chapter_audio_with_control(
        &output,
        "cancelled",
        true,
        Some(&control),
        Some(1),
        Some(0),
        |pending| {
            fs::write(pending, &old)?;
            control.cancel();
            Ok(())
        },
    );
    assert!(matches!(cancelled, Err(WorkerError::Cancelled)));
    assert_eq!(fs::read(&output).unwrap(), new);
    assert_eq!(
        fs::read(chapter_audio_receipt_path(&output)).unwrap(),
        receipt
    );
}

#[test]
fn listening_generates_and_persists_only_the_requested_unicode_remainder() {
    let temporary = tempfile::tempdir().unwrap();
    let input = temporary.path().join("listening.epub");
    platform_test_book_with_text(
        &input,
        "Skipped words. 🙂 Selected sentence continues to the end.",
    );
    let book =
        crate::epub::parse_epub(std::io::BufReader::new(fs::File::open(&input).unwrap())).unwrap();
    let source = &book.chapters[0].text;
    let byte = source.find('🙂').unwrap();
    let offset = source[..byte].chars().count();
    let control = crate::conversion_control::ConversionControl::new();
    control
        .set_listening_position(ListeningPosition {
            version: 2,
            chapter_index: 0,
            text_offset: offset,
        })
        .unwrap();
    let spoken = Arc::new(Mutex::new(Vec::new()));
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temporary.path().to_owned(),
    ));
    let worker = ConversionWorker::new(config)
        .unwrap()
        .with_control(control)
        .with_platform_tts(Arc::new(TestSystem {
            texts: spoken.clone(),
        }));
    let mut request = preference_test_request();
    request.input = input;
    request.job_id = "listening-remainder".into();
    request.tts_preferences = Some(crate::tts_preferences::TtsPreferences {
        primary: crate::tts_preferences::TtsSelection {
            session: None,
            engine: "system".into(),
            model_id: None,
            voice: None,
        },
        ..Default::default()
    });
    let manifest = worker.run(request).unwrap();
    assert_eq!(manifest.chapters.len(), 1);
    assert_eq!(manifest.chapters[0].text_offset, offset);
    assert_eq!(spoken.lock().unwrap().join(" "), source[byte..].trim());
    let output = worker
        .config
        .paths
        .output_dir
        .join("listening-remainder")
        .join(&manifest.chapters[0].filename);
    crate::pcm::validate_mp3(&fs::read(output).unwrap()).unwrap();
}

#[test]
fn listening_control_holds_next_chapter_until_time_budget_and_rejects_unknown_targets() {
    let control = crate::conversion_control::ConversionControl::new();
    control
        .set_listening_position(ListeningPosition {
            version: 2,
            chapter_index: 0,
            text_offset: 0,
        })
        .unwrap();
    control.attach(&[0, 1, 2]).unwrap();
    assert_eq!(control.take().unwrap(), Some(0));
    assert!(!control.chapter_is_in_playback_window(1));
    control
        .playback_feedback(&PlaybackFeedback {
            generation: Some(0),
            version: 2,
            chapter_index: 0,
            remaining_audio_seconds: 4.0,
            playback_rate: 2.0,
        })
        .unwrap();
    assert_eq!(control.take().unwrap(), Some(1));
    assert!(!control.chapter_is_in_playback_window(2));
    let generation = control.listening_plan().unwrap().generation;
    control
        .set_listening_position(ListeningPosition {
            version: 2,
            chapter_index: 0,
            text_offset: 2,
        })
        .unwrap();
    assert!(!control.generation_is_current(Some(generation)));
    assert_eq!(control.take().unwrap(), Some(0));
    assert!(control
        .set_listening_position(ListeningPosition {
            version: 2,
            chapter_index: 8,
            text_offset: 0
        })
        .is_err());
    control.cancel();
    assert!(control.cancellation_token().is_cancelled());
}

#[test]
fn versioned_listening_rejects_uncaptured_legacy_selection_before_synthesis() {
    struct Speech {
        control: ConversionControl,
        calls: Arc<AtomicUsize>,
    }
    impl crate::platform_tts::PlatformTts for Speech {
        fn synthesize_wav(
            &self,
            _: &str,
            _: &str,
            output: &std::path::Path,
            _: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), String> {
            if self.calls.fetch_add(1, Ordering::AcqRel) > 0 {
                self.control.cancel();
                return Err("Unexpected regeneration of a current source range".into());
            }
            fs::write(output, test_system_wav()).map_err(|error| error.to_string())
        }
    }
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("legacy-listening.epub");
    platform_test_book_with_text(&input, "Skipped. Selected words.");
    let control = ConversionControl::new();
    control
        .set_listening_position(ListeningPosition {
            version: 2,
            chapter_index: 0,
            text_offset: 9,
        })
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let chunks = Arc::new(AtomicUsize::new(0));
    let observed = chunks.clone();
    let worker = ConversionWorker::new(AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temp.path().into(),
    )))
    .unwrap()
    .with_control(control.clone())
    .with_platform_tts(Arc::new(Speech {
        control,
        calls: calls.clone(),
    }))
    .with_streaming_chunks(Arc::new(move |_, _, _| {
        observed.fetch_add(1, Ordering::AcqRel);
        true
    }));
    let mut request = preference_test_request();
    request.input = input;
    request.tts_preferences = None;
    request.engine = Some("system".into());
    assert!(
        matches!(worker.run(request), Err(WorkerError::Unsupported(message))
        if message.contains("requires captured TTS preferences"))
    );
    assert_eq!(calls.load(Ordering::Acquire), 0);
    assert_eq!(chunks.load(Ordering::Acquire), 0);
}

#[test]
fn manual_to_listening_requires_capture_without_publishing_or_retrying_old_audio() {
    struct Speech {
        control: ConversionControl,
        calls: Arc<AtomicUsize>,
    }
    impl crate::platform_tts::PlatformTts for Speech {
        fn synthesize_wav(
            &self,
            _: &str,
            _: &str,
            output: &std::path::Path,
            _: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), String> {
            if self.calls.fetch_add(1, Ordering::AcqRel) > 0 {
                self.control.cancel();
                return Err("Unexpected retry of an uncaptured listening selection".into());
            }
            self.control
                .set_listening_position(ListeningPosition {
                    version: 2,
                    chapter_index: 0,
                    text_offset: 9,
                })
                .unwrap();
            fs::write(output, test_system_wav()).map_err(|error| error.to_string())
        }
    }
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("manual-to-listening.epub");
    platform_test_book_with_text(&input, "Skipped. Selected words.");
    let control = ConversionControl::new();
    let calls = Arc::new(AtomicUsize::new(0));
    let worker = ConversionWorker::new(AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temp.path().into(),
    )))
    .unwrap()
    .with_control(control.clone())
    .with_platform_tts(Arc::new(Speech {
        control,
        calls: calls.clone(),
    }))
    .with_streaming_chunks(Arc::new(|_, _, _| panic!("Retired manual audio escaped")));
    let mut request = preference_test_request();
    request.input = input;
    request.tts_preferences = None;
    request.engine = Some("system".into());
    assert!(
        matches!(worker.run(request), Err(WorkerError::Unsupported(message))
        if message.contains("requires captured TTS preferences"))
    );
    assert_eq!(calls.load(Ordering::Acquire), 1);
}
