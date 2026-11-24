// BOOK-LANGUAGE-PROFILE: a book is classified from its whole text; a monolingual book is read
// entirely with its main language's voice, however many quotations in other languages it has.

const PORTUGUESE: &str = "A tarde caiu devagar sobre a casa do jardim e ninguém ousou romper o silêncio que se instalara entre as velhas paredes. ";
const FRENCH_QUOTE: &str = "Il faut cultiver notre jardin, disait le vieux philosophe, car le monde est trop vaste pour que nous puissions le changer tout entier. Voilà ce que je pense de la vie et de tous ses malheurs.";

/// Records the language each session was prepared for and the text of every segment.
fn run_language_book(
    paragraphs: Vec<String>,
    language: Option<&str>,
) -> Result<(Vec<String>, Vec<String>), WorkerError> {
    use crate::tts_session::*;
    struct Provider {
        languages: Arc<Mutex<Vec<String>>>,
        texts: Arc<Mutex<Vec<String>>>,
        descriptor: ProviderDescriptor,
    }
    struct Session {
        identity: ResolvedIdentity,
        texts: Arc<Mutex<Vec<String>>>,
    }
    impl TtsProvider for Provider {
        fn descriptor(&self) -> ProviderDescriptor {
            self.descriptor.clone()
        }
        fn prepare(&self, selection: &SessionSelection, language: &str) -> Result<Box<dyn TtsSession>, TtsFailure> {
            self.languages.lock().unwrap().push(language.to_owned());
            Ok(Box::new(Session {
                identity: ResolvedIdentity {
                    selection: selection.clone(),
                    runtime_revision: self.descriptor.revision.clone(),
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
        fn synthesize(&mut self, text: &str, context: &SynthesisContext<'_>, sink: &mut AudioSink) -> Result<(), TtsFailure> {
            context.check()?;
            self.texts.lock().unwrap().push(text.into());
            sink.write(&test_system_wav())
        }
    }
    let temporary = tempfile::tempdir().unwrap();
    let input = temporary.path().join("language.epub");
    multi_chapter_book(&input, &[paragraphs]);
    let languages = Arc::new(Mutex::new(Vec::new()));
    let texts = Arc::new(Mutex::new(Vec::new()));
    let descriptor = builtin_descriptors()
        .into_iter()
        .find(|descriptor| descriptor.provider == "piper" && descriptor.runtime == "piper")
        .expect("built-in piper descriptor");
    let mut registry = TtsRegistry::default();
    registry
        .register(Arc::new(Provider {
            languages: languages.clone(),
            texts: texts.clone(),
            descriptor,
        }))
        .unwrap();
    let config = AppConfig::from_paths(crate::paths::resolve_paths_from(
        Vec::<(String, String)>::new(),
        temporary.path().to_owned(),
    ));
    let worker = ConversionWorker::new(config)
        .unwrap()
        .with_tts_registry(registry);
    let mut request = preference_test_request();
    request.input = input;
    request.job_id = "language-profile".into();
    request.language = language.map(str::to_owned);
    request.tts_preferences = Some(crate::tts_preferences::TtsPreferences {
        primary: crate::tts_preferences::TtsSelection {
            session: Some(SessionSelection::from_legacy(&crate::tts_preferences::TtsSelection::default()).unwrap()),
            ..Default::default()
        },
        ..Default::default()
    });
    worker.run(request)?;
    let languages = languages.lock().unwrap().clone();
    let texts = texts.lock().unwrap().clone();
    Ok((languages, texts))
}

fn portuguese_paragraphs(count: usize) -> Vec<String> {
    (0..count).map(|i| format!("{PORTUGUESE}Parágrafo {i} do livro inteiro, escrito em português do Brasil.")).collect()
}

#[test]
fn a_monolingual_book_with_a_french_quotation_plays_entirely_with_its_own_voice() {
    let mut paragraphs = portuguese_paragraphs(40);
    paragraphs.insert(20, FRENCH_QUOTE.to_owned());
    let (languages, texts) = run_language_book(paragraphs, None)
        .expect("a quotation in another language must not stop the book");
    assert!(
        languages.iter().all(|language| language.starts_with("pt")),
        "every session must be prepared for Portuguese: {languages:?}"
    );
    assert!(texts.iter().any(|text| text.contains("Il faut cultiver")), "the quotation is read too");
}

const ENGLISH: &str = "The afternoon fell slowly over the house in the garden and nobody dared to break the silence that had settled between the old walls. ";

#[test]
fn a_bilingual_book_without_a_model_for_the_second_language_never_stops() {
    // Alternating Portuguese and English sections; the only voice is the Portuguese Faber model.
    let mut paragraphs = Vec::new();
    for index in 0..30 {
        paragraphs.push(format!("{PORTUGUESE}{PORTUGUESE}{PORTUGUESE}Seção {index} em português."));
        paragraphs.push(format!("{ENGLISH}{ENGLISH}Section {index} in English."));
    }
    let (languages, texts) = run_language_book(paragraphs, None)
        .expect("a passage without a voice is read with the main voice, never an error");
    assert!(
        languages.iter().all(|language| language.starts_with("pt")),
        "no session may be prepared for a language without a model: {languages:?}"
    );
    assert!(texts.iter().any(|text| text.contains("afternoon fell")), "the English sections are read too");
}

#[test]
fn the_profile_of_a_synthetic_bilingual_book_file_is_bilingual() {
    let temporary = tempfile::tempdir().unwrap();
    let input = temporary.path().join("bilingual.epub");
    let mut chapters = Vec::new();
    for index in 0..4 {
        let language = if index % 2 == 0 { PORTUGUESE } else { ENGLISH };
        chapters.push((0..12).map(|_| language.repeat(2)).collect::<Vec<_>>());
    }
    multi_chapter_book(&input, &chapters);
    let (analysis, profile) = crate::language::analyze_book_file_with_profile(&input, &|| false).unwrap();
    assert_eq!(profile.class, crate::language::profile::BookLanguageClass::Bilingual, "{profile:?}");
    assert_eq!(profile.languages.len(), 2);
    assert!(analysis.samples_examined > 0);
}
