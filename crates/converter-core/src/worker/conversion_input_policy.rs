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
    let lower = text.to_ascii_lowercase();
    let markers = [
        ("pt-BR", [" que ", " não ", " uma ", " para ", " você "]),
        ("it-IT", [" che ", " non ", " una ", " per ", " della "]),
        ("es-ES", [" que ", " no ", " una ", " para ", " los "]),
        ("en-US", [" the ", " and ", " not ", " this ", " with "]),
    ];
    markers
        .into_iter()
        .max_by_key(|(_, words)| words.iter().filter(|word| lower.contains(**word)).count())
        .and_then(|(language, words)| {
            (words.iter().filter(|word| lower.contains(**word)).count() >= 2).then_some(language)
        })
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
