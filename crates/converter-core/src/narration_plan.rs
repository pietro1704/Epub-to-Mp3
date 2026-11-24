//! The narration plan of one book (card RUST-NARRATION-PLAN, design 2026-11-24).
//!
//! One pure answer for every client before any audio: the book's language decision, the voice that reads the
//! main language (the listener's own voice for this book first, then the language's choice, the saved default,
//! the best installed model, the system voice), the voice of each other language the book is written in, and
//! what to tell the listener when a voice is missing. Pure: no I/O, never downloads.
use crate::language::decision::{decide, LanguageDecision};
use crate::language::profile::{BookLanguageProfile, LanguageRole};
use crate::language::BookLanguageAnalysis;
use crate::language_model_resolution::{resolve, Resolution, ResolutionRequest, Status};
use crate::model_catalog::ModelPlatform;
use crate::tts_preferences::TtsSelection;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const SCHEMA_VERSION: u32 = 1;

fn enabled() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct PlanRequest {
    pub schema_version: u32,
    /// The language the user set for the whole book.
    #[serde(default)]
    pub user_correction: Option<String>,
    #[serde(default)]
    pub declared: Option<String>,
    #[serde(default)]
    pub analysis: Option<BookLanguageAnalysis>,
    #[serde(default)]
    pub profile: Option<BookLanguageProfile>,
    /// The voice the listener set for this one book; applies to the main language only.
    #[serde(default)]
    pub book_voice: Option<TtsSelection>,
    #[serde(default)]
    pub per_language_choices: BTreeMap<String, TtsSelection>,
    #[serde(default)]
    pub primary: Option<TtsSelection>,
    #[serde(default)]
    pub allow_online_fallback: bool,
    #[serde(default = "enabled")]
    pub allow_automatic_system_voice_fallback: bool,
    #[serde(default)]
    pub installed_model_ids: Vec<String>,
    #[serde(default)]
    pub system_voices: Vec<String>,
    pub platform: ModelPlatform,
    #[serde(default)]
    pub android_api: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MissingNotice {
    pub language: String,
    pub role: LanguageRole,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct NarrationPlan {
    pub schema_version: u32,
    pub decision: LanguageDecision,
    /// How the main language is narrated; absent while the language is undetermined.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main: Option<Resolution>,
    /// The voice of each other language of the profile that has a usable one (base tag -> selection).
    pub language_voices: BTreeMap<String, TtsSelection>,
    /// The main language has no usable voice: alert before any audio.
    pub main_missing: bool,
    /// Significant languages without a voice: one notice per book. Section and incidental languages stay silent.
    pub notify_missing: Vec<MissingNotice>,
    /// Nothing determined the language: the client asks once (the declared tag is preselected in `decision`).
    pub needs_language_question: bool,
}

pub fn plan(request: &PlanRequest) -> NarrationPlan {
    let decision = decide(
        request.user_correction.as_deref(),
        request.profile.as_ref(),
        request.analysis.as_ref(),
        request.declared.as_deref(),
    );
    let Some(main_language) = decision.language.clone() else {
        return NarrationPlan {
            schema_version: SCHEMA_VERSION,
            needs_language_question: true,
            decision,
            main: None,
            language_voices: BTreeMap::new(),
            main_missing: false,
            notify_missing: Vec::new(),
        };
    };
    let resolution_request = |language: &str, book_voice: Option<TtsSelection>| ResolutionRequest {
        schema_version: crate::language_model_resolution::SCHEMA_VERSION,
        book_language: language.to_owned(),
        per_language_choices: request.per_language_choices.clone(),
        book_voice,
        primary: request.primary.clone(),
        allow_online_fallback: request.allow_online_fallback,
        allow_automatic_system_voice_fallback: request.allow_automatic_system_voice_fallback,
        installed_model_ids: request.installed_model_ids.clone(),
        system_voices: request.system_voices.clone(),
        platform: request.platform,
        android_api: request.android_api,
    };
    let main = resolve(&resolution_request(
        &main_language,
        request.book_voice.clone(),
    ));
    let main_base = base(&main_language);
    let mut language_voices = BTreeMap::new();
    let mut notify_missing = Vec::new();
    // The listener's book voice reads the main language only: every other language of the profile has its own.
    for share in request
        .profile
        .iter()
        .flat_map(|profile| profile.languages.iter())
    {
        let language = base(&share.language);
        if language == main_base {
            continue;
        }
        let resolution = resolve(&resolution_request(&share.language, None));
        match (resolution.status, resolution.selection) {
            (Status::Selected | Status::SystemFallback, Some(selection)) => {
                language_voices.insert(language, selection);
            }
            _ if share.role == LanguageRole::Significant => notify_missing.push(MissingNotice {
                language,
                role: share.role,
            }),
            _ => {}
        }
    }
    NarrationPlan {
        schema_version: SCHEMA_VERSION,
        needs_language_question: false,
        main_missing: main.status == Status::MissingModel,
        decision,
        main: Some(main),
        language_voices,
        notify_missing,
    }
}

fn base(language: &str) -> String {
    language
        .split(['-', '_'])
        .next()
        .unwrap_or(language)
        .to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::decision::DecisionSource;
    use crate::language::profile::{BookLanguageClass, LanguageShare};
    use crate::language_model_resolution::Source;

    fn piper(id: &str) -> TtsSelection {
        TtsSelection {
            session: None,
            engine: "piper".into(),
            model_id: Some(id.into()),
            voice: None,
        }
    }

    fn share(language: &str, fraction: f64, role: LanguageRole) -> LanguageShare {
        LanguageShare {
            language: language.into(),
            chars: (fraction * 10_000.0) as usize,
            fraction,
            longest_section_chars: if role == LanguageRole::Section {
                2_000
            } else {
                9_000
            },
            role,
        }
    }

    fn profile(shares: Vec<LanguageShare>, incidental: &[&str]) -> BookLanguageProfile {
        BookLanguageProfile {
            version: crate::language::profile::PROFILE_VERSION,
            detector: crate::language::profile::DETECTOR.into(),
            class: match shares.len() {
                0 | 1 => BookLanguageClass::Monolingual,
                2 => BookLanguageClass::Bilingual,
                _ => BookLanguageClass::Multilingual,
            },
            primary: shares.first().map(|share| share.language.clone()),
            languages: shares,
            incidental: incidental.iter().map(|tag| (*tag).to_owned()).collect(),
            total_chars: 10_000,
            undetermined_chars: 0,
        }
    }

    fn request(profile: Option<BookLanguageProfile>, installed: &[&str]) -> PlanRequest {
        PlanRequest {
            schema_version: SCHEMA_VERSION,
            user_correction: None,
            declared: None,
            analysis: None,
            profile,
            book_voice: None,
            per_language_choices: BTreeMap::new(),
            primary: Some(piper("pt_BR-faber-medium")),
            allow_online_fallback: false,
            allow_automatic_system_voice_fallback: false,
            installed_model_ids: installed.iter().map(|id| (*id).to_owned()).collect(),
            system_voices: Vec::new(),
            platform: ModelPlatform::Macos,
            android_api: None,
        }
    }

    fn portuguese() -> BookLanguageProfile {
        profile(vec![share("pt-BR", 1.0, LanguageRole::Main)], &["fr-FR"])
    }

    #[test]
    fn a_monolingual_book_with_quotations_is_narrated_by_its_main_languages_voice() {
        let plan = plan(&request(Some(portuguese()), &["pt_BR-faber-medium"]));
        assert_eq!(plan.decision.language.as_deref(), Some("pt-BR"));
        assert_eq!(plan.decision.source, DecisionSource::Profile);
        let main = plan.main.expect("main resolution");
        assert_eq!(main.status, Status::Selected);
        assert_eq!(main.source, Some(Source::Primary));
        assert!(
            plan.language_voices.is_empty(),
            "A quotation language gets no voice of its own"
        );
        assert!(
            !plan.main_missing && plan.notify_missing.is_empty() && !plan.needs_language_question
        );
    }

    #[test]
    fn the_listeners_voice_for_the_book_wins_for_the_main_language_only() {
        let mut r = request(
            Some(profile(
                vec![
                    share("pt-BR", 0.7, LanguageRole::Main),
                    share("en-US", 0.3, LanguageRole::Significant),
                ],
                &[],
            )),
            &[
                "pt_BR-faber-medium",
                "pt_BR-cadu-medium",
                "en_US-ljspeech-high",
            ],
        );
        r.book_voice = Some(piper("pt_BR-cadu-medium"));
        let plan = plan(&r);
        let main = plan.main.expect("main");
        assert_eq!(main.source, Some(Source::BookVoice));
        assert_eq!(main.selection, Some(piper("pt_BR-cadu-medium")));
        // The book voice never reads the other language: it keeps the automatic voice of that language.
        assert_eq!(
            plan.language_voices.get("en"),
            Some(&piper("en_US-ljspeech-high"))
        );
        assert!(!plan.language_voices.contains_key("pt"));
    }

    #[test]
    fn an_unusable_book_voice_falls_back_to_the_languages_voice_and_says_why() {
        let mut r = request(Some(portuguese()), &["pt_BR-faber-medium"]);
        r.book_voice = Some(piper("pt_BR-jeff-medium"));
        let main = plan(&r).main.expect("main");
        assert_eq!(main.source, Some(Source::Primary));
        assert_eq!(
            main.reasons.first().map(String::as_str),
            Some("book_voice:model_not_installed")
        );
    }

    #[test]
    fn a_missing_main_voice_alerts_before_any_audio() {
        let plan = plan(&request(Some(portuguese()), &[]));
        assert!(plan.main_missing);
        assert_eq!(plan.main.expect("main").status, Status::MissingModel);
    }

    #[test]
    fn only_a_significant_language_without_a_voice_is_notified() {
        let r = request(
            Some(profile(
                vec![
                    share("pt-BR", 0.8, LanguageRole::Main),
                    share("en-US", 0.12, LanguageRole::Significant),
                    share("de-DE", 0.08, LanguageRole::Section),
                ],
                &["fr-FR"],
            )),
            &["pt_BR-faber-medium"],
        );
        let plan = plan(&r);
        assert_eq!(
            plan.notify_missing,
            vec![MissingNotice {
                language: "en".into(),
                role: LanguageRole::Significant
            }],
            "A section language and the incidental quotation stay silent"
        );
        assert!(!plan.main_missing);
        assert!(plan.language_voices.is_empty());
    }

    #[test]
    fn an_undetermined_language_asks_once_and_resolves_nothing() {
        let mut r = request(Some(profile(vec![], &[])), &["pt_BR-faber-medium"]);
        r.declared = Some("pt-BR".into());
        let plan = plan(&r);
        assert!(plan.needs_language_question);
        assert!(plan.main.is_none() && !plan.main_missing);
        assert_eq!(plan.decision.preselect.as_deref(), Some("pt-BR"));
    }

    #[test]
    fn the_users_correction_decides_the_language_the_voice_is_resolved_for() {
        let mut r = request(
            Some(portuguese()),
            &["pt_BR-faber-medium", "en_US-ljspeech-high"],
        );
        r.user_correction = Some("en-US".into());
        r.primary = None;
        let main = plan(&r).main.expect("main");
        assert_eq!(main.book_language, "en-US");
        assert_eq!(main.selection, Some(piper("en_US-ljspeech-high")));
    }

    #[test]
    fn the_json_contract_is_snake_case_and_additive() {
        let request: PlanRequest = serde_json::from_str(
            r#"{"schema_version":1,"platform":"Macos","installed_model_ids":["pt_BR-faber-medium"],
                "profile":{"version":2,"detector":"whatlang-0.18/book-profile-v1","class":"monolingual","primary":"pt-BR",
                "languages":[{"language":"pt-BR","chars":900,"fraction":1.0,"longest_section_chars":900}],
                "incidental":[],"total_chars":900,"undetermined_chars":0}}"#,
        )
        .expect("a minimal request");
        let value = serde_json::to_value(plan(&request)).expect("json");
        for key in [
            "schema_version",
            "decision",
            "main",
            "language_voices",
            "main_missing",
            "notify_missing",
            "needs_language_question",
        ] {
            assert!(value.get(key).is_some(), "{key} in {value}");
        }
        assert_eq!(value["decision"]["source"], "profile");
        assert_eq!(value["main"]["status"], "selected");
    }
}
