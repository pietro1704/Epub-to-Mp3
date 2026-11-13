use super::*;

const ENGLISH: &str = "The reader opens the book and follows the story. The characters travel through a beautiful country and discover a small village where their friends are waiting for them. They listen carefully to the words and enjoy every chapter of this wonderful book. ";
const PORTUGUESE: &str = "O leitor abre o livro e acompanha a história. As personagens viajam por um país maravilhoso e descobrem uma pequena aldeia onde os amigos estão à sua espera. Elas escutam cuidadosamente as palavras e aproveitam cada capítulo deste livro interessante. ";

#[test]
fn incorrect_metadata_cannot_override_unanimous_representative_content() {
    let text = PORTUGUESE.repeat(30);
    let result = analyze_book([text.as_str()], Some("en-US"), &|| false).unwrap();
    assert_eq!(result.confirmed.as_deref(), Some("pt-BR"));
    assert!(result.samples_examined >= 3);
    assert_eq!(result.inconclusive_samples, 0);
    assert_eq!(result.declared.as_deref(), Some("en-US"));
}

#[test]
fn every_sampled_language_remains_visible_in_a_bilingual_book() {
    let english = ENGLISH.repeat(12);
    let portuguese = PORTUGUESE.repeat(12);
    let result = analyze_book([english.as_str(), portuguese.as_str()], Some("en"), &|| {
        false
    })
    .unwrap();
    assert!(result.confirmed.is_none());
    assert!(result
        .languages
        .iter()
        .any(|language| base(language) == "en"));
    assert!(result
        .languages
        .iter()
        .any(|language| base(language) == "pt"));
    assert!(result.samples_examined <= MAX_SAMPLES);
}

#[test]
fn unknown_opening_expands_sampling_and_unreadable_content_never_uses_metadata_as_fact() {
    let unknown = "Xqvz krpt qtxz wvrq psxz rqjk qzwr xkqr ".repeat(40);
    let english = ENGLISH.repeat(20);
    let result = analyze_book([unknown.as_str(), english.as_str()], Some("pt-BR"), &|| {
        false
    })
    .unwrap();
    assert!(result.samples_examined > 5);
    assert!(result
        .languages
        .iter()
        .any(|language| base(language) == "en"));
    assert!(result.confirmed.is_none());
    let empty = analyze_book(["12345"], Some("pt-BR"), &|| false).unwrap();
    assert!(empty.confirmed.is_none());
    assert!(empty.languages.is_empty());
}

#[test]
fn cancellation_stops_analysis_before_further_source_work() {
    assert!(analyze_book([ENGLISH], None, &|| true).is_err());
}

#[test]
fn bilingual_passages_preserve_both_languages_and_exact_source_order() {
    let text = format!("{ENGLISH}\n{PORTUGUESE}");
    let end = ENGLISH.chars().count() + 1;
    let result = passages(&text, &[end], None, &[], 0, 0, None);
    assert_eq!(
        result
            .first()
            .and_then(|value| value.language.as_deref())
            .map(base),
        Some("en")
    );
    assert_eq!(
        result
            .last()
            .and_then(|value| value.language.as_deref())
            .map(base),
        Some("pt")
    );
    let recovered = result
        .iter()
        .map(|passage| &text[passage.bytes.clone()])
        .collect::<String>();
    assert_eq!(recovered, text);
    for pair in result.windows(2) {
        assert_eq!(pair[0].bytes.end, pair[1].bytes.start);
        assert_eq!(pair[0].scalars.end, pair[1].scalars.start);
    }
}

#[test]
fn explicit_correction_is_scoped_and_survives_a_streaming_source_offset() {
    let text = format!("{ENGLISH}{PORTUGUESE}");
    let start = ENGLISH.chars().count();
    let correction = LanguageOverride {
        chapter_index: 3,
        start,
        end: text.chars().count(),
        language: "fr-FR".into(),
    };
    let result = passages(
        PORTUGUESE,
        &[],
        Some("pt-BR"),
        &[correction.clone()],
        3,
        start,
        None,
    );
    assert!(result
        .iter()
        .all(|passage| passage.language.as_deref() == Some("fr-FR")));
    let unrelated = passages(
        PORTUGUESE,
        &[],
        Some("pt-BR"),
        &[correction],
        4,
        start,
        None,
    );
    assert!(unrelated
        .iter()
        .all(|passage| passage.language.as_deref() == Some("pt-BR")));
}

#[test]
fn compatible_secondary_is_language_routing_without_mutating_preferences() {
    let primary = crate::tts_preferences::TtsPreferences::app_default(true);
    let english = preferences_for_language(&primary, Some("en-US"));
    assert_eq!(english.primary.engine, "system");
    assert_eq!(
        primary.primary.model_id.as_deref(),
        Some("pt_BR-faber-medium")
    );
    assert_eq!(preferences_for_language(&primary, Some("pt-BR")), primary);
}

#[test]
fn markup_language_is_validated_and_its_region_is_preserved_when_content_agrees() {
    assert_eq!(
        markup_language("<html xml:lang=\"pt-PT\"><body>text</body></html>"),
        Some("pt-PT".into())
    );
    assert_eq!(detect(PORTUGUESE, Some("pt-PT")).as_deref(), Some("pt-PT"));
    assert!(markup_language("<html lang=\"../../invalid\"><body>text</body></html>").is_none());
}

#[test]
fn short_bilingual_content_cannot_be_confirmed_from_a_mixed_majority_sample() {
    let text = format!("Chapter {ENGLISH}{PORTUGUESE}");
    let analysis = analyze_book([text.as_str()], Some("en"), &|| false).unwrap();
    assert!(analysis.confirmed.is_none());
    assert_eq!(analysis.languages.len(), 2);
}

#[test]
fn strict_legacy_model_mismatch_preserves_language_and_model_for_native_recovery() {
    let preferences = crate::tts_preferences::TtsPreferences::app_default(false);
    let error = preferences.primary.validate(Some("en-GB")).unwrap_err();
    assert!(error.contains("supports Portuguese"));
    let json = error
        .split("[[tts_language_mismatch_v1]]")
        .nth(1)
        .unwrap()
        .split("[[/tts_language_mismatch_v1]]")
        .next()
        .unwrap();
    let context: serde_json::Value = serde_json::from_str(json).unwrap();
    assert_eq!(context["language"], "en-GB");
    assert_eq!(context["model_id"], "pt_BR-faber-medium");
}

#[test]
fn short_japanese_passage_keeps_its_language_inside_an_english_book() {
    let japanese = "これは日本語の文章です。";
    assert!(japanese.chars().count() < 24);
    assert_eq!(detect(japanese, Some("en-US")).as_deref(), Some("ja"));
    let text = format!("{ENGLISH}{japanese}");
    let passages = passages(&text, &[], Some("en-US"), &[], 0, 0, None);
    assert_eq!(passages.last().unwrap().language.as_deref(), Some("ja"));
}

#[test]
fn cancellation_interrupts_candidate_collection_inside_one_long_chapter() {
    let text = ENGLISH.repeat(10_000);
    let checks = std::cell::Cell::new(0);
    let result = analyze_book([text.as_str()], None, &|| {
        checks.set(checks.get() + 1);
        checks.get() > 4
    });
    assert!(result.is_err());
    assert!(checks.get() < 10);
}
