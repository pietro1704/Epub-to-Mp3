use super::*;
use crate::model_catalog::catalog_languages;

fn piper(id: &str) -> TtsSelection {
    TtsSelection {
        session: None,
        engine: "piper".into(),
        model_id: Some(id.into()),
        voice: None,
    }
}

fn engine(name: &str) -> TtsSelection {
    TtsSelection {
        session: None,
        engine: name.into(),
        model_id: None,
        voice: None,
    }
}

fn request(language: &str, installed: &[&str]) -> ResolutionRequest {
    ResolutionRequest {
        schema_version: SCHEMA_VERSION,
        book_language: language.into(),
        per_language_choices: BTreeMap::new(),
        primary: None,
        allow_online_fallback: false,
        allow_automatic_system_voice_fallback: true,
        installed_model_ids: installed.iter().map(|id| (*id).to_owned()).collect(),
        system_voices: Vec::new(),
        platform: ModelPlatform::Macos,
        android_api: None,
    }
}

#[test]
fn per_language_choice_wins_over_primary_and_automatic() {
    let mut r = request("pt-BR", &["pt_BR-cadu-medium", "pt_BR-faber-medium"]);
    r.per_language_choices
        .insert("pt".into(), piper("pt_BR-cadu-medium"));
    r.primary = Some(piper("pt_BR-faber-medium"));
    let out = resolve(&r);
    assert_eq!(out.status, Status::Selected);
    assert_eq!(out.source, Some(Source::PerLanguage));
    assert_eq!(out.selection, Some(piper("pt_BR-cadu-medium")));
    assert!(out.reasons.is_empty());
}

#[test]
fn an_uninstalled_choice_is_skipped_never_selected() {
    let mut r = request("pt", &["pt_BR-faber-medium"]);
    r.per_language_choices
        .insert("pt".into(), piper("pt_BR-jeff-medium"));
    r.primary = Some(piper("pt_BR-faber-medium"));
    let out = resolve(&r);
    assert_eq!(out.source, Some(Source::Primary));
    assert_eq!(
        out.reasons,
        vec!["per_language_choice:model_not_installed".to_owned()]
    );
}

#[test]
fn an_incompatible_primary_is_skipped_for_the_best_installed_model() {
    let mut r = request("en-US", &["pt_BR-faber-medium", "en_US-ljspeech-high"]);
    r.primary = Some(piper("pt_BR-faber-medium"));
    let out = resolve(&r);
    assert_eq!(out.source, Some(Source::Automatic));
    assert_eq!(out.selection, Some(piper("en_US-ljspeech-high")));
    assert_eq!(
        out.reasons,
        vec!["primary:model_incompatible_with_language".to_owned()]
    );
}

#[test]
fn online_choice_needs_the_consent() {
    let mut r = request("pt", &["pt_BR-faber-medium"]);
    r.per_language_choices.insert("pt".into(), engine("edge"));
    let skipped = resolve(&r);
    assert_eq!(skipped.source, Some(Source::Automatic));
    assert_eq!(
        skipped.reasons,
        vec!["per_language_choice:online_requires_consent".to_owned()]
    );
    r.allow_online_fallback = true;
    let chosen = resolve(&r);
    assert_eq!(chosen.source, Some(Source::PerLanguage));
    assert_eq!(chosen.selection, Some(engine("edge")));
}

#[test]
fn the_system_voice_is_a_language_choice_and_a_setting_gated_fallback() {
    let mut r = request("en", &[]);
    r.system_voices = vec!["en-US".into()];
    let fallback = resolve(&r);
    assert_eq!(fallback.status, Status::SystemFallback);
    assert_eq!(fallback.source, Some(Source::System));
    assert_eq!(fallback.selection, Some(engine("system")));

    r.allow_automatic_system_voice_fallback = false;
    let off = resolve(&r);
    assert_eq!(off.status, Status::MissingModel);
    assert!(off.reasons.contains(&"system_fallback_disabled".to_owned()));

    // Chosen explicitly for its language it is used even with the fallback setting off.
    r.per_language_choices.insert("en".into(), engine("system"));
    let chosen = resolve(&r);
    assert_eq!(chosen.status, Status::Selected);
    assert_eq!(chosen.source, Some(Source::PerLanguage));
}

#[test]
fn a_system_voice_for_another_language_does_not_count() {
    let mut r = request("en", &[]);
    r.system_voices = vec!["pt-BR".into()];
    r.per_language_choices.insert("en".into(), engine("system"));
    let out = resolve(&r);
    assert_eq!(out.status, Status::MissingModel);
    assert!(out
        .reasons
        .contains(&"per_language_choice:no_system_voice_for_language".to_owned()));
}

#[test]
fn nothing_installed_reports_ranked_installable_suggestions_and_no_selection() {
    let out = resolve(&request("pt-BR", &[]));
    assert_eq!(out.status, Status::MissingModel);
    assert!(out.selection.is_none() && out.source.is_none());
    let missing = out.missing.unwrap();
    assert_eq!(missing.language, "pt");
    assert!(!missing.suggested.is_empty() && missing.suggested.len() <= 3);
    assert!(missing
        .suggested
        .iter()
        .all(|model| model.engine == "piper"));
    assert!(out
        .reasons
        .contains(&"automatic:no_installed_model".to_owned()));
}

#[test]
fn an_unknown_language_is_missing_with_no_suggestions() {
    let out = resolve(&request("xx", &["pt_BR-faber-medium"]));
    assert_eq!(out.status, Status::MissingModel);
    assert!(out.missing.unwrap().suggested.is_empty());
}

#[test]
fn catalog_languages_are_sorted_distinct_base_tags_with_models() {
    let languages = catalog_languages(ModelPlatform::Macos, None);
    let tags: Vec<_> = languages
        .iter()
        .map(|language| language.tag.as_str())
        .collect();
    let mut sorted = tags.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(tags, sorted);
    assert!(tags.contains(&"pt") && tags.contains(&"en"));
    assert!(languages.iter().all(|language| language.model_count > 0));
}

#[test]
fn json_contract_defaults_and_snake_case_response() {
    let request: ResolutionRequest =
        serde_json::from_str(r#"{"schema_version":1,"book_language":"pt-BR","platform":"Macos"}"#)
            .unwrap();
    assert!(request.allow_automatic_system_voice_fallback);
    assert!(!request.allow_online_fallback);
    let json = serde_json::to_value(resolve(&request)).unwrap();
    assert_eq!(json["status"], "missing_model");
    assert_eq!(json["schema_version"], 1);
    assert!(json.get("selection").is_none());
    assert_eq!(json["missing"]["language"], "pt");
}
