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
fn catalog_languages_carry_the_shared_popularity_rank() {
    let languages = catalog_languages(ModelPlatform::Macos, None);
    let rank = |tag: &str| {
        languages
            .iter()
            .find(|language| language.tag == tag)
            .and_then(|language| language.popularity_rank)
    };
    // Most popular first; the rank is the position in the one shared list.
    assert_eq!(rank("en"), Some(1));
    assert!(rank("es") < rank("pt") && rank("pt") < rank("fr"));
    let mut ranks: Vec<u32> = languages
        .iter()
        .filter_map(|language| language.popularity_rank)
        .collect();
    let count = ranks.len();
    ranks.sort_unstable();
    ranks.dedup();
    assert_eq!(ranks.len(), count, "ranks are unique");
    // A catalog language outside the list has no rank and is sorted alphabetically by clients.
    assert!(languages
        .iter()
        .any(|language| language.popularity_rank.is_none()));
    let json = serde_json::to_value(&languages[0]).unwrap();
    assert_eq!(
        json.get("popularity_rank").is_some(),
        languages[0].popularity_rank.is_some()
    );
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

#[test]
fn the_automatic_step_follows_the_jobs_own_ranking_before_any_other_installed_model() {
    // The job's automatic Piper ranking prefers the high-quality English voice over the medium one.
    let both = resolve(&request(
        "en-US",
        &["en_US-ljspeech-medium", "en_US-ljspeech-high"],
    ));
    assert_eq!(both.source, Some(Source::Automatic));
    assert_eq!(both.selection, Some(piper("en_US-ljspeech-high")));
    // Only the lower-ranked one installed: it is still used rather than reporting a missing model.
    let medium = resolve(&request("en-US", &["en_US-ljspeech-medium"]));
    assert_eq!(medium.selection, Some(piper("en_US-ljspeech-medium")));
}

#[test]
fn a_portuguese_book_keeps_faber_first_and_falls_back_to_another_installed_voice() {
    let with_faber = resolve(&request("pt", &["pt_BR-cadu-medium", "pt_BR-faber-medium"]));
    assert_eq!(
        with_faber.selection,
        Some(piper("pt_BR-faber-medium")),
        "the app's Portuguese default"
    );
    let only_cadu = resolve(&request("pt-BR", &["pt_BR-cadu-medium"]));
    assert_eq!(only_cadu.selection, Some(piper("pt_BR-cadu-medium")));
}

#[test]
fn a_different_language_without_a_choice_never_keeps_an_incompatible_primary() {
    // Primary pt Faber, English book, nothing English installed: system voice (setting on), else missing.
    let mut r = request("en", &["pt_BR-faber-medium"]);
    r.primary = Some(piper("pt_BR-faber-medium"));
    r.system_voices = vec!["en-US".into()];
    let system = resolve(&r);
    assert_eq!(system.status, Status::SystemFallback);
    assert!(system
        .reasons
        .contains(&"primary:model_incompatible_with_language".to_owned()));
    r.allow_automatic_system_voice_fallback = false;
    let missing = resolve(&r);
    assert_eq!(missing.status, Status::MissingModel);
    assert!(!missing.missing.unwrap().suggested.is_empty());
    // With an English model installed it is chosen before the system voice.
    r.installed_model_ids.push("en_US-ljspeech-high".into());
    r.allow_automatic_system_voice_fallback = true;
    let english = resolve(&r);
    assert_eq!(english.source, Some(Source::Automatic));
    assert_eq!(english.selection, Some(piper("en_US-ljspeech-high")));
}

#[test]
fn a_book_compatible_with_the_primary_keeps_it_exactly_as_today() {
    let mut r = request("pt-BR", &["pt_BR-faber-medium", "pt_BR-cadu-medium"]);
    r.primary = Some(piper("pt_BR-faber-medium"));
    let out = resolve(&r);
    assert_eq!(out.source, Some(Source::Primary));
    assert_eq!(out.selection, r.primary);
}

fn explicit_low(id: &str) -> TtsSelection {
    let model = crate::model_catalog::model_by_id(id).unwrap();
    let mut selection = piper(id);
    let mut session = crate::tts_session::SessionSelection::from_legacy(&selection).unwrap();
    session.model_revision = crate::model_catalog::model_revision(model);
    selection.session = Some(session);
    selection
}

#[test]
fn an_installed_low_voice_is_never_picked_automatically_nor_suggested() {
    for (language, low) in [
        ("pt-BR", "pt_BR-edresson-low"),
        ("en-US", "en_US-lessac-low"),
    ] {
        // Only the Low voice installed and nothing chosen: no automatic pick, a missing-model result.
        let mut only_low = request(language, &[low]);
        only_low.allow_automatic_system_voice_fallback = false;
        let out = resolve(&only_low);
        assert_eq!(
            out.status,
            Status::MissingModel,
            "{low} must not be automatic"
        );
        assert!(out.selection.is_none());
        assert!(out
            .reasons
            .contains(&"automatic:no_installed_model".to_owned()));
        // The system voice (setting on) is the fallback, not the Low voice.
        let mut with_system = request(language, &[low]);
        with_system.system_voices = vec![language.into()];
        assert_eq!(resolve(&with_system).status, Status::SystemFallback);
        // Suggestions never offer a Low voice, installed or not.
        let none = {
            let mut r = request(language, &[]);
            r.allow_automatic_system_voice_fallback = false;
            resolve(&r)
        };
        let suggested = none.missing.unwrap().suggested;
        assert!(!suggested.is_empty());
        assert!(
            suggested
                .iter()
                .all(|model| !model.model_id.ends_with("-low")),
            "{suggested:?}"
        );
        // A better installed voice still wins over an installed Low one.
        let better = if language == "pt-BR" {
            "pt_BR-faber-medium"
        } else {
            "en_US-ljspeech-medium"
        };
        assert_eq!(
            resolve(&request(language, &[low, better])).selection,
            Some(piper(better))
        );
    }
}

#[test]
fn an_explicit_low_choice_is_honored_but_only_with_its_revision_and_its_language() {
    let low = "pt_BR-edresson-low";
    let mut explicit = request("pt-BR", &[low, "pt_BR-faber-medium"]);
    explicit
        .per_language_choices
        .insert("pt".into(), explicit_low(low));
    let out = resolve(&explicit);
    assert_eq!(out.source, Some(Source::PerLanguage));
    assert_eq!(out.selection, Some(explicit_low(low)));
    // The saved default may be an explicit Low voice too (validated by the preferences).
    let mut primary = request("pt-BR", &[low]);
    primary.primary = Some(explicit_low(low));
    assert_eq!(resolve(&primary).source, Some(Source::Primary));
    // The same voice without the revision is not an explicit opt-in: skipped, never silently used.
    let mut bare = request("pt-BR", &[low, "pt_BR-faber-medium"]);
    bare.per_language_choices.insert("pt".into(), piper(low));
    let skipped = resolve(&bare);
    assert_eq!(skipped.source, Some(Source::Automatic));
    assert_eq!(skipped.selection, Some(piper("pt_BR-faber-medium")));
    assert!(skipped
        .reasons
        .contains(&"per_language_choice:model_incompatible_with_language".to_owned()));
    // A wrong revision is rejected too.
    let mut stale = explicit_low(low);
    stale.session.as_mut().unwrap().model_revision = Some("obsolete".into());
    let mut wrong = request("pt-BR", &[low, "pt_BR-faber-medium"]);
    wrong.per_language_choices.insert("pt".into(), stale);
    assert_eq!(resolve(&wrong).selection, Some(piper("pt_BR-faber-medium")));
    // An explicit Low voice of another language is never used for this book.
    let mut other = request("en-US", &[low, "en_US-ljspeech-medium"]);
    other
        .per_language_choices
        .insert("en".into(), explicit_low(low));
    assert_eq!(
        resolve(&other).selection,
        Some(piper("en_US-ljspeech-medium"))
    );
}
