use super::*;

#[test]
fn portuguese_sentence_endings_survive_phonemization() {
    let sentences =
        text_to_phonemes("Olá, João. Você está bem? Que ótimo!", "pt-br", None).unwrap();
    assert_eq!(sentences.len(), 3);
    for (sentence, ending) in sentences.iter().zip(['.', '?', '!']) {
        assert!(
            sentence.ends_with(ending),
            "{sentence:?} must end in {ending}"
        );
    }
    assert!(sentences[0].contains(", "));
}

#[test]
fn portuguese_subclauses_keep_punctuation_and_word_separation() {
    let sentences = text_to_phonemes("Primeiro, ouça: leia; depois fale.", "pt-br", None).unwrap();
    assert_eq!(sentences.len(), 1);
    for boundary in [", ", ": ", "; "] {
        assert!(
            sentences[0].contains(boundary),
            "Missing {boundary:?}: {sentences:?}"
        );
    }
}

#[test]
fn accented_text_and_decimal_comma_remain_inside_the_sentence() {
    let sentences = text_to_phonemes("A maçã custa 3,14 reais. Está bom?", "pt-br", None).unwrap();
    assert_eq!(sentences.len(), 2);
    assert!(sentences[0].ends_with('.'));
    assert!(sentences[1].ends_with('?'));
    assert!(
        !sentences[0].contains(", "),
        "A decimal is not a clause break"
    );
    assert!(!sentences.join("").contains('\u{fffd}'));
}

#[test]
fn empty_input_and_unpunctuated_eof_do_not_invent_punctuation() {
    assert!(text_to_phonemes("", "pt-br", None).unwrap().is_empty());
    let sentences = text_to_phonemes("Olá", "pt-br", None).unwrap();
    assert_eq!(sentences.len(), 1);
    assert!(!sentences[0].ends_with(['.', '?', '!']));
}

#[test]
fn invalid_requests_leave_the_next_valid_voice_usable() {
    let expected = text_to_phonemes("Olá, João!", "pt-br", None).unwrap();
    for (text, voice) in [
        ("Olá", "missing-voice-for-regression"),
        ("Olá\0João", "pt-br"),
        ("Olá", "pt\0br"),
    ] {
        assert!(text_to_phonemes(text, voice, None).is_err());
        assert_eq!(
            text_to_phonemes("Olá, João!", "pt-br", None).unwrap(),
            expected
        );
    }
}

#[test]
fn concurrent_requests_preserve_each_voice_and_its_clause_buffer() {
    let input = "Olá, João! Você está bem?";
    let voices = ["pt-br", "en-US", "ar"];
    let expected: Vec<_> = voices
        .iter()
        .map(|voice| text_to_phonemes(input, voice, None).unwrap())
        .collect();
    assert_ne!(expected[0], expected[1]);
    std::thread::scope(|scope| {
        for (voice, expected) in voices.iter().zip(&expected) {
            scope.spawn(move || {
                for _ in 0..4 {
                    assert_eq!(&text_to_phonemes(input, voice, None).unwrap(), expected);
                }
            });
        }
    });
}
