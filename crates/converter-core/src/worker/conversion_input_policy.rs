use super::WorkerError;
use crate::{config::AppConfig, piper};

pub(super) fn chapter_selection_matches(value: &str, chapter_index: &str, position: usize) -> bool {
    value == chapter_index
        || value
            .strip_prefix("position:")
            .unwrap_or(value)
            .parse::<usize>()
            .map(|index| index == position)
            .unwrap_or(false)
}

pub(super) fn detect_language(text: &str) -> Option<&'static str> {
    let lower = text.to_lowercase();
    let markers = [
        ("pt-BR", [" que ", " não ", " uma ", " para ", " você "]),
        ("it-IT", [" che ", " non ", " una ", " per ", " della "]),
        ("es-ES", [" que ", " no ", " una ", " para ", " los "]),
        ("en-US", [" the ", " and ", " not ", " this ", " with "]),
    ];
    markers
        .into_iter()
        .map(|(language, words)| {
            let common_words = words.iter().filter(|word| lower.contains(**word)).count();
            // Portuguese nasal vowels distinguish its contractions from Spanish
            // negation. Shared words alone must not outweigh that source evidence.
            let portuguese_hint =
                usize::from(language == "pt-BR" && (lower.contains('ã') || lower.contains('õ')))
                    * 2;
            (language, common_words + portuguese_hint)
        })
        .max_by_key(|(_, score)| *score)
        .and_then(|(language, score)| (score >= 2).then_some(language))
}

#[cfg(test)]
mod language_tests {
    use super::detect_language;

    #[test]
    fn portuguese_pdf_contractions_do_not_become_spanish_negation() {
        let text =
            "Parte 1 - PDF para áudio\nOlá. Este PDF verifica a conversão para áudio no iPhone.";
        assert_eq!(detect_language(text), Some("pt-BR"));
        assert_eq!(detect_language(&text.to_uppercase()), Some("pt-BR"));
    }

    #[test]
    fn other_languages_and_unknown_text_keep_their_identity() {
        assert_eq!(
            detect_language("Un texto para los lectores que no escuchan."),
            Some("es-ES")
        );
        assert_eq!(
            detect_language("The reader and this book work with audio."),
            Some("en-US")
        );
        assert_eq!(
            detect_language("The reader and this book mention João with audio."),
            Some("en-US")
        );
        assert_eq!(
            detect_language("Una pagina per chi non ascolta della musica."),
            Some("it-IT")
        );
        assert_eq!(detect_language("12345"), None);
        assert_eq!(detect_language("PDF audio"), None);
    }
}

pub(super) fn default_edge_voice(language: Option<&str>) -> &'static str {
    match language.unwrap_or_default().to_ascii_lowercase().as_str() {
        "pt" | "pt-br" | "pt_br" => "pt-BR-FranciscaNeural",
        "it" | "it-it" => "it-IT-ElsaNeural",
        "es" | "es-es" | "es-mx" => "es-ES-ElviraNeural",
        "en" | "en-us" | "en-gb" => "en-US-GuyNeural",
        _ => "en-US-EmmaMultilingualNeural",
    }
}

pub(super) fn ensure_android_piper_runtime(
    status: piper::PiperRuntimeStatus,
) -> Result<(), WorkerError> {
    if !status.runtime_loaded || !status.abi_compatible {
        return Err(WorkerError::Piper(
            "Embedded Piper runtime is unavailable or ABI-incompatible on Android".into(),
        ));
    }
    Ok(())
}

pub(super) fn select_engine(request: Option<&str>, config: &AppConfig) -> String {
    match request
        .unwrap_or(&config.engine)
        .to_ascii_lowercase()
        .as_str()
    {
        "piper" => "piper".into(),
        "system" => "system".into(),
        _ => "edge".into(),
    }
}
pub(super) fn sanitize(value: &str) -> String {
    let mut s = value
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, '-' | '_' | ' ' | '.') {
                c
            } else {
                '_'
            }
        })
        .collect::<String>();
    s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.is_empty() {
        "book".into()
    } else {
        s
    }
}
