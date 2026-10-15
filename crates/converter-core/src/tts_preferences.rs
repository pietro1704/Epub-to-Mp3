//! Shared, platform-independent voice selection and isolated-segment policy.
use serde::{Deserialize, Serialize};

pub const FABER_MODEL_ID: &str = "pt_BR-faber-medium";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TtsSelection {
    pub engine: String,
    #[serde(default)]
    pub model_id: Option<String>,
    #[serde(default)]
    pub voice: Option<String>,
}
impl Default for TtsSelection {
    fn default() -> Self {
        Self {
            engine: "piper".into(),
            model_id: Some(FABER_MODEL_ID.into()),
            voice: None,
        }
    }
}
impl TtsSelection {
    pub fn validate(&self, language: Option<&str>) -> Result<(), String> {
        if !matches!(self.engine.as_str(), "piper" | "edge" | "system") {
            return Err(format!("Unsupported TTS engine: {}", self.engine));
        }
        if self.engine != "edge" && self.voice.is_some() {
            return Err("Voice identifiers are supported by Edge; local voices are selected through their model".into());
        }
        if self.engine == "piper" {
            let id = self
                .model_id
                .as_deref()
                .ok_or("Piper requires a model ID")?;
            if id.is_empty() || id.contains('/') || id.contains('\\') || id == "." || id == ".." {
                return Err("Invalid Piper model ID".into());
            }
            if id == FABER_MODEL_ID
                && language.is_some_and(|lang| {
                    !lang.eq_ignore_ascii_case("pt")
                        && !lang.eq_ignore_ascii_case("pt-BR")
                        && !lang.eq_ignore_ascii_case("pt_BR")
                })
            {
                return Err(
                    "Faber medium supports Portuguese; choose a compatible voice for this book"
                        .into(),
                );
            }
        } else if self.model_id.is_some() {
            return Err("Only Piper selections accept a local model ID".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TtsPreferences {
    pub primary: TtsSelection,
    pub secondary: Option<TtsSelection>,
    pub allow_online_fallback: bool,
}
impl TtsPreferences {
    pub fn validate(&self, language: Option<&str>) -> Result<(), String> {
        self.primary.validate(language)?;
        if let Some(secondary) = &self.secondary {
            secondary.validate(language)?;
            if secondary == &self.primary {
                return Err("Secondary voice must differ from primary".into());
            }
            if secondary.engine == "edge" && !self.allow_online_fallback {
                return Err("Online Edge fallback requires explicit permission".into());
            }
        }
        Ok(())
    }
    pub fn effective_selection(
        &self,
        override_selection: Option<TtsSelection>,
        use_secondary: bool,
    ) -> Self {
        Self {
            primary: override_selection.unwrap_or_else(|| self.primary.clone()),
            secondary: if use_secondary {
                self.secondary.clone()
            } else {
                None
            },
            allow_online_fallback: self.allow_online_fallback,
        }
    }
    /// Serialized policy plus caller-supplied content identities; hash at the I/O seam.
    pub fn cache_fingerprint(&self, language: Option<&str>, model_content: &[String]) -> String {
        serde_json::to_string(&(self, language, model_content)).expect("TTS policy serialization")
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "SegmentPolicyState")]
pub struct SegmentPolicy {
    consecutive_failures: usize,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SegmentPolicyState {
    consecutive_failures: usize,
}
impl TryFrom<SegmentPolicyState> for SegmentPolicy {
    type Error = String;
    fn try_from(state: SegmentPolicyState) -> Result<Self, Self::Error> {
        if state.consecutive_failures > 2 {
            return Err("TTS policy state must contain zero to two consecutive failures".into());
        }
        Ok(Self {
            consecutive_failures: state.consecutive_failures,
        })
    }
}
impl SegmentPolicy {
    pub fn primary_succeeded(&mut self) {
        self.consecutive_failures = 0;
    }
    pub fn primary_failed(&mut self, cancelled: bool, has_secondary: bool) -> Result<(), String> {
        if cancelled {
            return Err("Conversion cancelled".into());
        }
        self.consecutive_failures += 1;
        if self.consecutive_failures >= 3 {
            return Err(
                "Primary voice failed for three consecutive segments; retry conversion".into(),
            );
        }
        if !has_secondary {
            return Err("Primary voice failed and no secondary voice is enabled".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_voice_identifiers_are_rejected_instead_of_silently_ignored() {
        let mut faber = TtsSelection::default();
        faber.voice = Some("unimplemented-speaker".into());
        assert!(faber.validate(Some("pt-BR")).is_err());
        let system = TtsSelection {
            engine: "system".into(),
            model_id: None,
            voice: Some("unimplemented-voice".into()),
        };
        assert!(system.validate(None).is_err());
        let edge = TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        };
        assert!(edge.validate(Some("pt-BR")).is_ok());
    }

    #[test]
    fn defaults_are_offline_faber() {
        let p = TtsPreferences::default();
        assert_eq!(p.primary.model_id.as_deref(), Some(FABER_MODEL_ID));
        assert!(p.secondary.is_none());
        assert!(!p.allow_online_fallback);
    }
    #[test]
    fn online_secondary_requires_consent() {
        let mut p = TtsPreferences::default();
        p.secondary = Some(TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: None,
        });
        assert!(p.validate(Some("pt-BR")).is_err());
        p.allow_online_fallback = true;
        assert!(p.validate(Some("pt-BR")).is_ok());
        assert!(p.validate(Some("en-US")).is_err());
    }
    #[test]
    fn failures_stop_and_success_resets() {
        let mut p = SegmentPolicy::default();
        assert!(p.primary_failed(false, true).is_ok());
        p.primary_succeeded();
        assert!(p.primary_failed(false, true).is_ok());
        assert!(p.primary_failed(false, true).is_ok());
        assert!(p.primary_failed(false, true).is_err());
        assert!(SegmentPolicy::default().primary_failed(true, true).is_err());
    }
    #[test]
    fn manual_override_is_immutable_and_cache_is_content_sensitive() {
        let p = TtsPreferences::default();
        let edge = TtsSelection {
            engine: "edge".into(),
            model_id: None,
            voice: Some("pt-BR-FranciscaNeural".into()),
        };
        let effective = p.effective_selection(Some(edge), false);
        assert_eq!(p.primary.engine, "piper");
        assert_eq!(effective.primary.engine, "edge");
        assert_ne!(
            p.cache_fingerprint(Some("pt"), &["hash-a".into()]),
            p.cache_fingerprint(Some("pt"), &["hash-b".into()])
        );
    }
}
