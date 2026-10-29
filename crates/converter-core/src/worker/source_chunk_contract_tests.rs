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
        sink.write(&platform_tts::encode_wav(&test_system_wav()).unwrap())
    }
}
fn chunk_preferences() -> TtsPreferences {
    TtsPreferences {
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
    assert_eq!(calls.lock().unwrap()[0], format!("Chapter {first}"));
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
