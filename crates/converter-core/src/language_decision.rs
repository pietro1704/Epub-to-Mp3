//! The language a book is narrated in (card RUST-BOOK-LANGUAGE-DECISION).
//!
//! One decision for every client and for the job set-up. Precedence: the user's correction, then the
//! whole-book profile's primary language, then the sampled consensus (`confirmed`). The declared metadata
//! never decides: it only carries the region, breaks a tie within [`TIE_POINTS`] (see the profile), preselects
//! the choice offered to the user when nothing was determined, and is reported when it contradicts the text.
use super::profile::BookLanguageProfile;
use super::BookLanguageAnalysis;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionSource {
    UserCorrection,
    Profile,
    Confirmed,
    /// Nothing determined the language: the client asks once.
    Undetermined,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LanguageDecision {
    pub language: Option<String>,
    pub source: DecisionSource,
    /// Undetermined only: the declared tag, to preselect in the question.
    pub preselect: Option<String>,
    /// The file declares another base language than the text is written in. Reported, never an alert.
    pub declared_conflict: Option<String>,
}

pub fn decide(
    user_correction: Option<&str>,
    profile: Option<&BookLanguageProfile>,
    analysis: Option<&BookLanguageAnalysis>,
    declared: Option<&str>,
) -> LanguageDecision {
    let _ = (user_correction, profile, analysis, declared);
    LanguageDecision {
        language: None,
        source: DecisionSource::Undetermined,
        preselect: None,
        declared_conflict: None,
    }
}

impl LanguageDecision {
    /// Whether the job set-up must stop and ask: nothing determined the language, no passage was corrected
    /// and the sampling did not even see two languages to route between.
    pub fn blocks_job(&self, has_passage_overrides: bool, sampled_languages: usize) -> bool {
        let _ = (has_passage_overrides, sampled_languages);
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::profile::{BookLanguageClass, LanguageRole, LanguageShare};

    fn share(language: &str, fraction: f64, longest: usize, role: LanguageRole) -> LanguageShare {
        LanguageShare {
            language: language.into(),
            chars: (fraction * 10_000.0) as usize,
            fraction,
            longest_section_chars: longest,
            role,
        }
    }

    fn profile(primary: Option<&str>) -> BookLanguageProfile {
        BookLanguageProfile {
            version: crate::language::profile::PROFILE_VERSION,
            detector: crate::language::profile::DETECTOR.into(),
            class: BookLanguageClass::Monolingual,
            primary: primary.map(str::to_owned),
            languages: primary
                .map(|tag| vec![share(tag, 1.0, 9_000, LanguageRole::Main)])
                .unwrap_or_default(),
            incidental: vec!["fr-FR".into()],
            total_chars: 10_000,
            undetermined_chars: 0,
        }
    }

    fn analysis(confirmed: Option<&str>, languages: &[&str]) -> BookLanguageAnalysis {
        BookLanguageAnalysis {
            confirmed: confirmed.map(str::to_owned),
            languages: languages.iter().map(|tag| (*tag).to_owned()).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn the_user_correction_wins_over_the_profile_and_the_samples() {
        let decision = decide(
            Some("en-US"),
            Some(&profile(Some("pt-BR"))),
            Some(&analysis(Some("fr-FR"), &["fr-FR", "pt-BR"])),
            Some("pt"),
        );
        assert_eq!(decision.language.as_deref(), Some("en-US"));
        assert_eq!(decision.source, DecisionSource::UserCorrection);
    }

    #[test]
    fn the_profile_primary_wins_over_the_sampled_consensus() {
        // 32 samples happened to confirm French in a Portuguese book with French quotations.
        let decision = decide(
            None,
            Some(&profile(Some("pt-BR"))),
            Some(&analysis(Some("fr-FR"), &["fr-FR", "pt-BR"])),
            Some("pt"),
        );
        assert_eq!(decision.language.as_deref(), Some("pt-BR"));
        assert_eq!(decision.source, DecisionSource::Profile);
    }

    #[test]
    fn the_sampled_consensus_decides_only_without_a_profile_primary_and_an_invalid_correction_is_ignored(
    ) {
        let decision = decide(
            Some("   "),
            Some(&profile(None)),
            Some(&analysis(Some("es-ES"), &["es-ES"])),
            None,
        );
        assert_eq!(decision.language.as_deref(), Some("es-ES"));
        assert_eq!(decision.source, DecisionSource::Confirmed);
        let older = decide(None, None, Some(&analysis(Some("es-ES"), &["es-ES"])), None);
        assert_eq!(
            older.language.as_deref(),
            Some("es-ES"),
            "An older library has no profile"
        );
    }

    #[test]
    fn the_declared_language_never_decides_it_only_preselects_the_question() {
        let decision = decide(
            None,
            Some(&profile(None)),
            Some(&analysis(None, &[])),
            Some("pt-BR"),
        );
        assert_eq!(
            decision.language, None,
            "Metadata alone is never turned into a language"
        );
        assert_eq!(decision.source, DecisionSource::Undetermined);
        assert_eq!(decision.preselect.as_deref(), Some("pt-BR"));
        let determined = decide(None, Some(&profile(Some("pt-BR"))), None, Some("pt-BR"));
        assert_eq!(
            determined.preselect, None,
            "A determined language is not asked"
        );
    }

    #[test]
    fn a_declared_language_that_contradicts_the_text_is_reported_not_obeyed() {
        let decision = decide(None, Some(&profile(Some("pt-BR"))), None, Some("en"));
        assert_eq!(decision.language.as_deref(), Some("pt-BR"));
        assert_eq!(decision.declared_conflict.as_deref(), Some("en"));
        let same_base = decide(None, Some(&profile(Some("pt-BR"))), None, Some("pt-PT"));
        assert_eq!(
            same_base.declared_conflict, None,
            "Same base language: only the region differs"
        );
    }

    #[test]
    fn the_job_stops_only_when_nothing_determined_the_language() {
        let undetermined = decide(
            None,
            Some(&profile(None)),
            Some(&analysis(None, &["fr-FR"])),
            Some("pt"),
        );
        assert!(undetermined.blocks_job(false, 1));
        assert!(
            !undetermined.blocks_job(true, 1),
            "A passage correction lets the job proceed"
        );
        assert!(
            !undetermined.blocks_job(false, 2),
            "Two sampled languages are routed per passage"
        );
        // The sampling was inconclusive but the whole-book profile found the language: no error (F2).
        let by_profile = decide(
            None,
            Some(&profile(Some("pt-BR"))),
            Some(&analysis(None, &["fr-FR"])),
            None,
        );
        assert!(!by_profile.blocks_job(false, 1));
    }

    #[test]
    fn the_roles_of_a_bilingual_profile_are_main_significant_and_section() {
        let texts = [
            "A tarde caiu devagar sobre a casa do jardim e ninguém ousou romper o silêncio que se instalara entre as velhas paredes. ".repeat(80),
            "The afternoon fell slowly over the house in the garden and nobody dared to break the silence that had settled between the old walls. ".repeat(12),
        ];
        let profile = crate::language::profile::profile(
            texts.iter().map(String::as_str),
            Some("pt-BR"),
            &|| false,
        )
        .unwrap();
        assert_eq!(profile.languages[0].role, LanguageRole::Main);
        assert_eq!(
            profile.languages[1].role,
            LanguageRole::Section,
            "{profile:?}"
        );
    }

    #[test]
    fn the_declared_language_breaks_a_near_tie_but_never_outweighs_the_text() {
        let pt = "A tarde caiu devagar sobre a casa do jardim e ninguém ousou romper o silêncio que se instalara entre as velhas paredes. ";
        let en = "The afternoon fell slowly over the house in the garden and nobody dared to break the silence that had settled between the old walls. ";
        // English has slightly more text (a few points), the file says Portuguese: Portuguese leads.
        let near = [en.repeat(26), pt.repeat(25)];
        let tied = crate::language::profile::profile(
            near.iter().map(String::as_str),
            Some("pt-BR"),
            &|| false,
        )
        .unwrap();
        assert_eq!(
            tied.primary.as_deref().map(|tag| &tag[..2]),
            Some("pt"),
            "{tied:?}"
        );
        // A wide margin is content, whatever the file declares.
        let wide = [en.repeat(60), pt.repeat(20)];
        let clear = crate::language::profile::profile(
            wide.iter().map(String::as_str),
            Some("pt-BR"),
            &|| false,
        )
        .unwrap();
        assert_eq!(
            clear.primary.as_deref().map(|tag| &tag[..2]),
            Some("en"),
            "{clear:?}"
        );
    }
}
