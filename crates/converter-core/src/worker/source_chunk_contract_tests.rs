use super::*;
use crate::tts_preferences::{TtsPreferences, TtsSelection};
use crate::tts_session::*;

struct ChunkRecordingProvider(Arc<Mutex<Vec<String>>>);
struct ChunkRecordingSession(ResolvedIdentity, Arc<Mutex<Vec<String>>>);

impl TtsProvider for ChunkRecordingProvider {
    fn descriptor(&self) -> ProviderDescriptor {
        ProviderDescriptor {
            provider: "chunk-contract".into(),
            runtime: "recording-mp3".into(),
            revision: "1".into(),
            targets: vec!["test".into()],
            capabilities: TtsCapabilities {
                audio_formats: vec![AudioFormat::Mp3],
                languages: vec!["pt".into()],
                voices: vec![],
                voice_selection: false,
                configurable_options: vec![],
                max_text_chars: 96,
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
        _: &str,
    ) -> Result<Box<dyn TtsSession>, TtsFailure> {
        Ok(Box::new(ChunkRecordingSession(
            ResolvedIdentity {
                selection: selection.clone(),
                runtime_revision: "1".into(),
                artifacts: Default::default(),
                reusable: true,
            },
            self.0.clone(),
        )))
    }
}
impl TtsSession for ChunkRecordingSession {
    fn identity(&self) -> &ResolvedIdentity {
        &self.0
    }
    fn synthesize(
        &mut self,
        text: &str,
        context: &SynthesisContext<'_>,
        sink: &mut AudioSink,
    ) -> Result<(), TtsFailure> {
        context.check()?;
        assert!(text.chars().count() <= 96);
        self.1.lock().unwrap().push(text.to_owned());
        let mut bytes = crate::speech_alignment::tag(&[crate::speech_alignment::Passage {
            version: 1,
            text: text.to_owned(),
            audio_start: 0.0,
            source_offset: None,
            note: None,
            words: vec![crate::speech_alignment::Word {
                location: 0,
                length: text
                    .split_whitespace()
                    .next()
                    .unwrap()
                    .encode_utf16()
                    .count(),
                start: 0.0,
                end: 0.05,
            }],
        }])
        .unwrap();
        bytes.extend(crate::pcm::encode_wav_mp3(&test_system_wav()).unwrap());
        sink.write(&bytes)
    }
}
fn chunk_preferences() -> TtsPreferences {
    TtsPreferences {
        footnote_narration: Default::default(),
        primary: TtsSelection {
            engine: "chunk-contract".into(),
            model_id: None,
            voice: None,
            session: Some(SessionSelection {
                version: CONTRACT_VERSION,
                provider: "chunk-contract".into(),
                runtime: "recording-mp3".into(),
                model_id: None,
                model_revision: None,
                voice: None,
                options: Default::default(),
            }),
        },
        secondary: None,
        allow_online_fallback: false,
        policy_version: None,
    }
}
fn chunk_worker(root: &Path, calls: Arc<Mutex<Vec<String>>>) -> ConversionWorker {
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        root.to_path_buf(),
    ));
    let mut registry = TtsRegistry::default();
    registry
        .register(Arc::new(ChunkRecordingProvider(calls)))
        .unwrap();
    ConversionWorker::new(config)
        .unwrap()
        .with_tts_registry(registry)
}

#[test]
fn typed_worker_consumes_boundary_whitespace_and_uses_paragraph_metadata() {
    let root = tempfile::tempdir().unwrap();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let worker = chunk_worker(root.path(), calls.clone());
    let first = "Água clara atravessa a aldeia tranquila antes de chegar ao moinho";
    let text = format!("  {first}   O segundo parágrafo continua pela estrada até a ponte.  ");
    let paragraph_end = first.chars().count() + 2;
    *worker.render_progress.lock().unwrap() =
        render_progress::RenderProgress::new([(0, text.chars().count())]);
    let output = root.path().join("planned.mp3");
    worker
        .synthesize_preferences_at_generation(
            &preference_test_request(),
            &chunk_preferences(),
            &text,
            &output,
            0,
            Some("pt-BR"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
            None,
            &[paragraph_end],
            &[],
            None,
        )
        .unwrap();
    assert_eq!(calls.lock().unwrap()[0], first);
    assert_eq!(
        worker
            .render_progress
            .lock()
            .unwrap()
            .snapshot()
            .unwrap()
            .fraction,
        1.0,
        "Canonical consumed source includes all boundary whitespace"
    );
    crate::pcm::validate_mp3(&fs::read(output).unwrap()).unwrap();
}

#[test]
fn epub_paragraph_projection_reaches_real_worker_and_completed_artifact() {
    let root = tempfile::tempdir().unwrap();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let worker = chunk_worker(root.path(), calls.clone());
    let first = "Água clara atravessa a aldeia tranquila antes de chegar ao moinho";
    let source = format!("{first}</p><p>O segundo parágrafo continua pela estrada até a ponte.");
    let input = root.path().join("paragraphs.epub");
    platform_test_book_with_text(&input, &source);
    let mut request = preference_test_request();
    request.input = input;
    request.job_id = "paragraph-worker".into();
    request.engine = Some("chunk-contract".into());
    request.tts_preferences = Some(chunk_preferences());
    let manifest = worker.run(request).unwrap();
    assert_eq!(calls.lock().unwrap()[0], "Chapter");
    assert_eq!(calls.lock().unwrap()[1], first);
    assert_eq!(manifest.chapters.len(), 1);
    assert_eq!(
        manifest.synthesis_sessions[0].selection.provider,
        "chunk-contract"
    );
}

#[test]
fn new_planner_profile_invalidates_legacy_whole_chapter_identity() {
    let root = tempfile::tempdir().unwrap();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let worker = chunk_worker(root.path(), calls.clone());
    let preferences = chunk_preferences();
    let request = preference_test_request();
    let current = worker
        .typed_cache_request_key(&request, &preferences, Some("pt-BR"), "source")
        .unwrap();
    let session = preferences.primary.session.as_ref().unwrap();
    let identity = ResolvedIdentity {
        selection: session.clone(),
        runtime_revision: "1".into(),
        artifacts: Default::default(),
        reusable: true,
    };
    let identities = vec![
        serde_json::to_string(&(
            CONTRACT_VERSION,
            "text-v1",
            session,
            ChunkRecordingProvider(calls).descriptor(),
            AudioFormat::Mp3,
        ))
        .unwrap(),
        cache_material("source", "text-v1", &identity, &AudioFormat::Mp3).unwrap(),
    ];
    let old = request_cache_material("source", Some("pt-BR"), &preferences, &identities).unwrap();
    assert_ne!(current, cache::sha256_bytes(old.as_bytes()));
    assert_eq!(
        current,
        worker
            .typed_cache_request_key(&request, &preferences, Some("pt-BR"), "source")
            .unwrap()
    );
}

#[test]
fn heading_pause_reaches_streamed_bytes_and_final_artifact_once() {
    let root = tempfile::tempdir().unwrap();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let chunks = Arc::new(Mutex::new(Vec::new()));
    let captured = chunks.clone();
    let worker = chunk_worker(root.path(), calls.clone()).with_streaming_chunks(Arc::new(
        move |_, _, bytes| {
            captured.lock().unwrap().push(bytes.to_vec());
            true
        },
    ));
    *worker.source_identity.lock().unwrap() = Some("heading-book".into());
    let text = "Title Ordinary body.";
    let output = root.path().join("heading.mp3");
    let synthesize = || {
        worker
            .synthesize_preferences_at_generation(
                &preference_test_request(),
                &chunk_preferences(),
                text,
                &output,
                0,
                Some("pt-BR"),
                &std::sync::atomic::AtomicBool::new(false),
                &Mutex::new(Vec::new()),
                1,
                None,
                &[5, text.chars().count()],
                &[5],
                None,
            )
            .unwrap()
    };
    synthesize();
    let original = fs::read(&output).unwrap();
    synthesize();
    assert_eq!(fs::read(&output).unwrap(), original);
    assert_eq!(*calls.lock().unwrap(), ["Title", "Ordinary body."]);
    let chunks = chunks.lock().unwrap();
    assert_eq!(
        chunks.len(),
        4,
        "The second playback reuses both cached segments"
    );
    assert_eq!(original, chunks[..2].concat());
    assert_eq!(chunks[..2], chunks[2..]);
    // Same speech for both segments: they differ only by the pause after each. The title
    // gets the heading pause and the body, which ends the chapter, the chapter-end pause.
    use super::super::heading_pauses::{pause_millis, Boundary};
    let engine = &chunk_preferences().primary.engine;
    let title_pause = pause_millis(Boundary::Heading, engine) as f64 / 1000.0;
    let end_pause = pause_millis(Boundary::ChapterEnd, engine) as f64 / 1000.0;
    let first = crate::pcm::mp3_duration_seconds(&chunks[0]).unwrap();
    let body = crate::pcm::mp3_duration_seconds(&chunks[1]).unwrap();
    assert!(
        ((first - body) - (title_pause - end_pause)).abs() < 0.08,
        "title={first}, body={body}, title pause={title_pause}, chapter end pause={end_pause}"
    );
}

#[test]
fn cached_equal_speech_is_bound_to_each_source_occurrence_after_reuse() {
    let root = tempfile::tempdir().unwrap();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let worker = chunk_worker(root.path(), calls.clone());
    *worker.source_identity.lock().unwrap() = Some("repeated-word-book".into());
    // Two headings with the same words and the same pause, then a different last paragraph.
    let text = "Echo. Echo. Tail.";
    let output = root.path().join("repeated.mp3");
    worker
        .synthesize_preferences_at_generation(
            &preference_test_request(),
            &chunk_preferences(),
            text,
            &output,
            0,
            Some("pt-BR"),
            &std::sync::atomic::AtomicBool::new(false),
            &Mutex::new(Vec::new()),
            1,
            None,
            &[5, 11, 17],
            &[5, 11],
            None,
        )
        .unwrap();
    assert_eq!(
        *calls.lock().unwrap(),
        ["Echo.", "Tail."],
        "Equal speech must still use the content-addressed cache"
    );
    let passages = crate::speech_alignment::collect(&mut fs::File::open(output).unwrap()).unwrap();
    assert_eq!(passages.len(), 3);
    assert_eq!(passages[0].source_offset, Some(0));
    assert_eq!(
        passages[1].source_offset,
        Some(6),
        "Cached speech must not retain the first occurrence's offset"
    );
}
