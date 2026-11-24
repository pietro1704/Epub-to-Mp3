// Streaming seek priority: a seek makes the target the top priority, even while a long chapter
// is in progress. The in-flight chapter yields at its next segment boundary and is resumed later.

fn multi_chapter_book(path: &Path, chapters: &[Vec<String>]) {
    let manifest: String = (0..chapters.len())
        .map(|i| format!("<item id=\"c{i}\" href=\"c{i}.xhtml\" media-type=\"application/xhtml+xml\"/>"))
        .collect();
    let spine: String = (0..chapters.len()).map(|i| format!("<itemref idref=\"c{i}\"/>")).collect();
    let package = format!("<package xmlns:dc=\"x\"><metadata><dc:title>Seek</dc:title><dc:language>pt-BR</dc:language></metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>");
    let mut entries: Vec<(String, Vec<u8>)> = vec![
        (
            "META-INF/container.xml".into(),
            b"<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>".to_vec(),
        ),
        ("content.opf".into(), package.into_bytes()),
    ];
    for (i, paragraphs) in chapters.iter().enumerate() {
        let body: String = paragraphs.iter().map(|text| format!("<p>{text}</p>")).collect();
        entries.push((
            format!("c{i}.xhtml"),
            format!("<html><body><h1>Capitulo {i}</h1>{body}</body></html>").into_bytes(),
        ));
    }
    fs::write(path, epub_fixture::epub_bytes(entries, zip::write::SimpleFileOptions::default())).unwrap();
}

/// Runs a three-chapter book whose first chapter is long; `seek` is invoked from inside the
/// synthesis of the third segment. Returns every synthesized text, in order, with the index of
/// the call that issued the seek.
fn run_with_seek(
    streaming: impl Fn(&crate::conversion_control::ConversionControl),
    seek: impl Fn(&crate::conversion_control::ConversionControl) + Send + Sync + 'static,
    stop_at_target: bool,
) -> (Vec<String>, usize) {
    use crate::tts_session::*;
    let _serial = crate::conversion_control::SEEK_TEST_GATE
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    struct Provider {
        texts: Arc<Mutex<Vec<String>>>,
        seek: Arc<dyn Fn() + Send + Sync>,
        seek_call: Arc<Mutex<Option<usize>>>,
        stop: Arc<dyn Fn() + Send + Sync>,
    }
    struct Session {
        identity: ResolvedIdentity,
        texts: Arc<Mutex<Vec<String>>>,
        seek: Arc<dyn Fn() + Send + Sync>,
        seek_call: Arc<Mutex<Option<usize>>>,
        stop: Arc<dyn Fn() + Send + Sync>,
    }
    impl TtsProvider for Provider {
        fn descriptor(&self) -> ProviderDescriptor {
            let mut descriptor = builtin_descriptors()[2].clone();
            descriptor.provider = "seek-fixture".into();
            descriptor.runtime = "wav-fixture".into();
            descriptor.revision = "test-1".into();
            descriptor
        }
        fn prepare(&self, selection: &SessionSelection, _: &str) -> Result<Box<dyn TtsSession>, TtsFailure> {
            Ok(Box::new(Session {
                identity: ResolvedIdentity {
                    selection: selection.clone(),
                    runtime_revision: "test-1".into(),
                    artifacts: Default::default(),
                    reusable: true,
                },
                texts: self.texts.clone(),
                seek: self.seek.clone(),
                seek_call: self.seek_call.clone(),
                stop: self.stop.clone(),
            }))
        }
    }
    impl TtsSession for Session {
        fn identity(&self) -> &ResolvedIdentity {
            &self.identity
        }
        fn synthesize(&mut self, text: &str, context: &SynthesisContext<'_>, sink: &mut AudioSink) -> Result<(), TtsFailure> {
            context.check()?;
            let call = {
                let mut texts = self.texts.lock().unwrap();
                texts.push(text.into());
                texts.len() - 1
            };
            // The seek happens while the first chapter is being synthesized (third segment).
            if call == 2 {
                *self.seek_call.lock().unwrap() = Some(call);
                (self.seek)();
            }
            if text.contains("ALVO") {
                (self.stop)();
            }
            sink.write(&test_system_wav())
        }
    }
    let temporary = tempfile::tempdir().unwrap();
    let input = temporary.path().join("seek.epub");
    let long: Vec<String> = (0..12).map(|i| format!("ZERO paragrafo {i} do capitulo longo.")).collect();
    multi_chapter_book(
        &input,
        &[long, vec!["UM unico paragrafo do segundo capitulo.".into()], vec!["ALVO paragrafo do capitulo alvo.".into()]],
    );
    let control = crate::conversion_control::ConversionControl::new();
    streaming(&control);
    let texts = Arc::new(Mutex::new(Vec::new()));
    let seek_call = Arc::new(Mutex::new(None));
    let seek_control = control.clone();
    let stop_control = control.clone();
    let mut registry = TtsRegistry::default();
    registry
        .register(Arc::new(Provider {
            texts: texts.clone(),
            seek: Arc::new(move || seek(&seek_control)),
            seek_call: seek_call.clone(),
            stop: Arc::new(move || {
                if stop_at_target {
                    stop_control.cancel();
                }
            }),
        }))
        .unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temporary.path().to_owned(),
    ));
    let worker = ConversionWorker::new(config)
        .unwrap()
        .with_control(control)
        .with_tts_registry(registry)
        .with_streaming_chunks(Arc::new(|_, _, _| true));
    let mut request = preference_test_request();
    request.input = input;
    request.job_id = "seek-priority".into();
    request.tts_preferences = Some(crate::tts_preferences::TtsPreferences {
        primary: crate::tts_preferences::TtsSelection {
            engine: "seek-fixture".into(),
            model_id: None,
            voice: None,
            session: Some(SessionSelection {
                version: 2,
                provider: "seek-fixture".into(),
                runtime: "wav-fixture".into(),
                model_id: None,
                model_revision: None,
                voice: None,
                options: Default::default(),
            }),
        },
        ..Default::default()
    });
    let outcome = worker.run(request);
    if !stop_at_target {
        outcome.unwrap();
    }
    let texts = texts.lock().unwrap().clone();
    let call = seek_call.lock().unwrap().expect("the seek was issued");
    (texts, call)
}

fn assert_target_follows_the_seek_within_one_segment(texts: &[String], seek_call: usize) {
    let first_target = texts
        .iter()
        .position(|text| text.contains("ALVO"))
        .expect("the target chapter was synthesized");
    assert!(
        first_target <= seek_call + 2,
        "the first target segment came {} segments after the seek: {:?}",
        first_target - seek_call,
        &texts[seek_call..first_target + 1]
    );
}

fn assert_preempted_chapter_resumes(texts: &[String]) {
    // The preempted chapter is resumed afterwards: its remaining paragraphs are synthesized too.
    assert!(texts.iter().filter(|text| text.contains("ZERO")).count() >= 12);
    assert!(texts.iter().any(|text| text.contains("UM unico")));
}

#[test]
fn prioritize_during_streaming_preempts_the_chapter_in_progress() {
    let (texts, seek_call) = run_with_seek(
        |control| control.set_playback_window(0, 3),
        |control| control.prioritize(2).unwrap(),
        false,
    );
    assert_target_follows_the_seek_within_one_segment(&texts, seek_call);
    assert_preempted_chapter_resumes(&texts);
}

#[test]
fn a_listening_seek_to_another_chapter_preempts_the_chapter_in_progress() {
    let (texts, seek_call) = run_with_seek(
        |control| {
            control
                .set_listening_position(crate::tts_session::ListeningPosition { version: 2, chapter_index: 0, text_offset: 0 })
                .unwrap();
        },
        |control| {
            control
                .set_listening_position(crate::tts_session::ListeningPosition { version: 2, chapter_index: 2, text_offset: 0 })
                .unwrap();
        },
        true,
    );
    assert_target_follows_the_seek_within_one_segment(&texts, seek_call);
}
