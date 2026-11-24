//! Which narration a book in a given language plays with (SETTINGS-MODELS-BY-LANGUAGE).
//!
//! Pure function: no I/O, no download, no clock. Clients persist one optional
//! choice per base language and pass what is installed; the result becomes the
//! job's primary selection, or tells the client that no model is available so
//! it can lead the user to the Models screen. A per-job selection never goes
//! through here. See `docs/models-by-language-contract.md`.
use crate::model_catalog::{candidates, ModelPlatform};
use crate::tts_preferences::TtsSelection;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const SCHEMA_VERSION: u32 = 1;
const MAX_SUGGESTIONS: usize = 3;

fn enabled() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ResolutionRequest {
    pub schema_version: u32,
    /// The language Rust confirmed for the book or the user corrected.
    pub book_language: String,
    /// One optional explicit choice per base language tag (`pt`, `en`, ...).
    #[serde(default)]
    pub per_language_choices: BTreeMap<String, TtsSelection>,
    /// The voice the listener set for this one book, if any (additive; decides before the language's choice).
    #[serde(default)]
    pub book_voice: Option<TtsSelection>,
    /// The user's default primary narration, if any.
    #[serde(default)]
    pub primary: Option<TtsSelection>,
    /// Online consent: an online (Edge) selection is skipped without it.
    #[serde(default)]
    pub allow_online_fallback: bool,
    /// The user setting (on by default) that lets the installed system voice
    /// stand in when no local model qualifies.
    #[serde(default = "enabled")]
    pub allow_automatic_system_voice_fallback: bool,
    #[serde(default)]
    pub installed_model_ids: Vec<String>,
    /// Languages (any tag) that have an installed system voice.
    #[serde(default)]
    pub system_voices: Vec<String>,
    pub platform: ModelPlatform,
    #[serde(default)]
    pub android_api: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Selected,
    SystemFallback,
    MissingModel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// The listener's own voice for this book.
    BookVoice,
    PerLanguage,
    Primary,
    Automatic,
    System,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SuggestedModel {
    pub model_id: String,
    pub engine: String,
    pub download_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MissingModel {
    pub language: String,
    pub suggested: Vec<SuggestedModel>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Resolution {
    pub schema_version: u32,
    pub book_language: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection: Option<TtsSelection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    /// Stable machine codes for every candidate that was skipped.
    pub reasons: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub missing: Option<MissingModel>,
}

fn base(language: &str) -> String {
    language
        .split(['-', '_'])
        .next()
        .unwrap_or(language)
        .to_ascii_lowercase()
}

struct Context<'a> {
    request: &'a ResolutionRequest,
    language: String,
}

impl Context<'_> {
    fn installed(&self, id: &str) -> bool {
        self.request
            .installed_model_ids
            .iter()
            .any(|installed| installed == id)
    }

    /// A Piper Low voice named with its catalog revision (the explicit opt-in) that supports this language.
    #[cfg(not(target_arch = "wasm32"))]
    fn explicit_low_supports_language(&self, selection: &TtsSelection) -> bool {
        selection
            .session
            .as_ref()
            .and_then(|session| session.explicit_low_piper_model())
            .is_some_and(|model| {
                selection.model_id.as_deref() == Some(model.id)
                    && model.runtime_available
                    && model.supports(
                        &self.language,
                        self.request.platform,
                        self.request.android_api,
                    )
            })
    }

    #[cfg(target_arch = "wasm32")]
    fn explicit_low_supports_language(&self, _selection: &TtsSelection) -> bool {
        false
    }

    fn has_system_voice(&self) -> bool {
        self.request
            .system_voices
            .iter()
            .any(|voice| base(voice) == self.language)
    }

    /// `Ok` when the selection can narrate this book now, else the skip reason. `explicit_choice` is true only
    /// for the listener's own choices (per-language or the saved default, which `TtsPreferences::validate` already
    /// holds to the catalog revision): the only places a revision-pinned Piper Low voice may be used, never an
    /// automatic pick, a suggestion or a fallback.
    fn usable(&self, selection: &TtsSelection, explicit_choice: bool) -> Result<(), &'static str> {
        match selection.engine.as_str() {
            "edge" if self.request.allow_online_fallback => Ok(()),
            "edge" => Err("online_requires_consent"),
            "system" if self.has_system_voice() => Ok(()),
            "system" => Err("no_system_voice_for_language"),
            "piper" => {
                let id = selection.model_id.as_deref().ok_or("model_not_named")?;
                if !self.installed(id) {
                    return Err("model_not_installed");
                }
                let compatible = candidates(
                    &self.language,
                    self.request.platform,
                    self.request.android_api,
                )
                .iter()
                .any(|model| model.id == id)
                    || (explicit_choice && self.explicit_low_supports_language(selection));
                if compatible {
                    Ok(())
                } else {
                    Err("model_incompatible_with_language")
                }
            }
            _ => Err("unsupported_engine"),
        }
    }
}

pub fn resolve(request: &ResolutionRequest) -> Resolution {
    let context = Context {
        request,
        language: base(&request.book_language),
    };
    let mut reasons = Vec::new();
    let mut chosen = None;
    if let Some(voice) = &request.book_voice {
        match context.usable(voice, true) {
            Ok(()) => chosen = Some((voice.clone(), Source::BookVoice)),
            Err(reason) => reasons.push(format!("book_voice:{reason}")),
        }
    }
    if let (None, Some(choice)) = (&chosen, request.per_language_choices.get(&context.language)) {
        match context.usable(choice, true) {
            Ok(()) => chosen = Some((choice.clone(), Source::PerLanguage)),
            Err(reason) => reasons.push(format!("per_language_choice:{reason}")),
        }
    }
    if chosen.is_none() {
        if let Some(primary) = &request.primary {
            match context.usable(primary, true) {
                Ok(()) => chosen = Some((primary.clone(), Source::Primary)),
                Err(reason) => reasons.push(format!("primary:{reason}")),
            }
        }
    }
    let all = candidates(&context.language, request.platform, request.android_api);
    if chosen.is_none() {
        // One decision, not two: the job's own automatic ranking (`piper-auto`) comes first, so a
        // client that sends `piper-auto` and one that resolves here pick the same voice; any other
        // installed compatible model follows rather than reporting a missing model.
        let ranked = crate::model_catalog::automatic_piper_models(&context.language)
            .into_iter()
            .filter(|model| all.iter().any(|supported| supported.id == model.id));
        if let Some(model) = ranked
            .chain(all.iter().copied().filter(|model| model.engine == "piper"))
            .find(|model| context.installed(model.id))
        {
            chosen = Some((
                TtsSelection {
                    session: None,
                    engine: "piper".into(),
                    model_id: Some(model.id.to_owned()),
                    voice: None,
                },
                Source::Automatic,
            ));
        } else {
            reasons.push("automatic:no_installed_model".into());
        }
    }
    let result = |status, selection, source, missing| Resolution {
        schema_version: SCHEMA_VERSION,
        book_language: request.book_language.clone(),
        status,
        selection,
        source,
        reasons: Vec::new(),
        missing,
    };
    let mut resolution = match chosen {
        Some((selection, source)) => result(Status::Selected, Some(selection), Some(source), None),
        None if request.allow_automatic_system_voice_fallback && context.has_system_voice() => {
            result(
                Status::SystemFallback,
                Some(TtsSelection {
                    session: None,
                    engine: "system".into(),
                    model_id: None,
                    voice: None,
                }),
                Some(Source::System),
                None,
            )
        }
        None => {
            if context.has_system_voice() {
                reasons.push("system_fallback_disabled".into());
            }
            let suggested = all
                .iter()
                .filter(|model| model.engine == "piper" && !context.installed(model.id))
                .take(MAX_SUGGESTIONS)
                .map(|model| SuggestedModel {
                    model_id: model.id.to_owned(),
                    engine: model.engine.to_owned(),
                    download_bytes: model.download_bytes,
                })
                .collect();
            result(
                Status::MissingModel,
                None,
                None,
                Some(MissingModel {
                    language: context.language.clone(),
                    suggested,
                }),
            )
        }
    };
    resolution.reasons = reasons;
    resolution
}

#[cfg(test)]
#[path = "language_model_resolution_tests.rs"]
mod tests;
