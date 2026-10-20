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
    /// Missing means the original strict job policy. Version 2 opts into native recovery.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub policy_version: Option<u8>,
    pub primary: TtsSelection,
    pub secondary: Option<TtsSelection>,
    pub allow_online_fallback: bool,
}
impl TtsPreferences {
    /// App settings opt into recovery; unversioned headless/job selections stay strict.
    pub fn app_default(system_audio_available: bool) -> Self {
        Self {
            policy_version: system_audio_available.then_some(2),
            secondary: system_audio_available.then(|| TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
            }),
            ..Self::default()
        }
    }
    pub fn continues_native(&self) -> bool {
        self.policy_version == Some(2)
    }

    pub fn validate(&self, language: Option<&str>) -> Result<(), String> {
        if self.policy_version.is_some_and(|v| v != 2) {
            return Err("Unsupported TTS policy version".into());
        }
        // App policy may recover through a compatible installed system voice.
        // Validate language eligibility at synthesis; captured strict jobs still
        // reject an incompatible primary before conversion starts.
        let primary_language = if self.continues_native() {
            None
        } else {
            language
        };
        self.primary.validate(primary_language)?;
        if let Some(secondary) = &self.secondary {
            secondary.validate(primary_language)?;
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
            policy_version: if use_secondary {
                self.policy_version
            } else {
                None
            },
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
    #[serde(default, skip_serializing_if = "is_zero")]
    recovery_remaining: usize,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    primary_retry_at_ms: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    secondary_retry_at_ms: u64,
}
fn is_zero_u64(value: &u64) -> bool {
    *value == 0
}
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}
fn is_zero(value: &usize) -> bool {
    *value == 0
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SegmentPolicyState {
    consecutive_failures: usize,
    #[serde(default)]
    recovery_remaining: usize,
    #[serde(default)]
    primary_retry_at_ms: u64,
    #[serde(default)]
    secondary_retry_at_ms: u64,
}
impl TryFrom<SegmentPolicyState> for SegmentPolicy {
    type Error = String;
    fn try_from(state: SegmentPolicyState) -> Result<Self, Self::Error> {
        if state.consecutive_failures > 2 || state.recovery_remaining > 8 {
            return Err("TTS policy state must contain zero to two consecutive failures".into());
        }
        Ok(Self {
            consecutive_failures: state.consecutive_failures,
            recovery_remaining: state.recovery_remaining,
            primary_retry_at_ms: state.primary_retry_at_ms,
            secondary_retry_at_ms: state.secondary_retry_at_ms,
        })
    }
}
impl SegmentPolicy {
    pub fn is_initial(&self) -> bool {
        self.consecutive_failures == 0
            && self.recovery_remaining == 0
            && self.primary_retry_at_ms == 0
            && self.secondary_retry_at_ms == 0
    }

    pub fn primary_succeeded(&mut self) {
        self.consecutive_failures = 0;
        self.recovery_remaining = 0;
        self.primary_retry_at_ms = 0;
    }
    pub fn secondary_succeeded(&mut self) {
        self.secondary_retry_at_ms = 0;
    }
    pub fn should_try_secondary(&self) -> bool {
        self.secondary_retry_at_ms <= now_ms()
    }
    pub fn defer_primary_for(&mut self, delay: std::time::Duration) {
        self.primary_retry_at_ms =
            now_ms().saturating_add(delay.as_millis().min(u128::from(u64::MAX)) as u64);
    }
    pub fn defer_secondary_for(&mut self, delay: std::time::Duration) {
        self.secondary_retry_at_ms =
            now_ms().saturating_add(delay.as_millis().min(u128::from(u64::MAX)) as u64);
    }
    /// Recovery counters are persisted with the job; cancellation never consumes a retry.
    pub fn should_try_primary(&mut self, preferences: &TtsPreferences) -> bool {
        if preferences.continues_native() && self.primary_retry_at_ms > now_ms() {
            return false;
        }
        if preferences.continues_native() && self.recovery_remaining > 0 {
            // Older jobs persisted an eight-segment cooldown. A single
            // fallback segment now bounds recovery latency without probing
            // concurrently or synthesizing throwaway health-check audio.
            self.recovery_remaining = 0;
            false
        } else {
            true
        }
    }
    pub fn provider_failed(
        &mut self,
        cancelled: bool,
        preferences: &TtsPreferences,
    ) -> Result<(), String> {
        if cancelled {
            return Err("Conversion cancelled".into());
        }
        if preferences.continues_native() {
            self.consecutive_failures = (self.consecutive_failures + 1).min(2);
            if self.consecutive_failures >= 2 {
                self.recovery_remaining = 1;
            }
            Ok(())
        } else {
            self.primary_failed(false, preferences.secondary.is_some())
        }
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
    fn rate_limit_health_checks_wait_and_survive_job_restart() {
        let preferences = TtsPreferences::app_default(true);
        let mut policy = SegmentPolicy::default();
        policy.defer_primary_for(std::time::Duration::from_secs(60));
        policy.defer_secondary_for(std::time::Duration::from_secs(60));
        let saved = serde_json::to_string(&policy).unwrap();
        let mut resumed: SegmentPolicy = serde_json::from_str(&saved).unwrap();
        assert!(!resumed.should_try_primary(&preferences));
        assert!(!resumed.should_try_secondary());
        assert_eq!(saved, serde_json::to_string(&resumed).unwrap());
        assert!(resumed.provider_failed(true, &preferences).is_err());
        assert_eq!(saved, serde_json::to_string(&resumed).unwrap());
        resumed.primary_succeeded();
        resumed.secondary_succeeded();
        assert!(resumed.should_try_primary(&preferences));
        assert!(resumed.should_try_secondary());
        assert!(resumed.is_initial());
    }
    #[test]
    fn app_policy_is_opt_in_and_legacy_snapshot_is_unchanged() {
        let app = TtsPreferences::app_default(true);
        assert!(app.continues_native());
        assert_eq!(app.primary.model_id.as_deref(), Some(FABER_MODEL_ID));
        assert!(!app.allow_online_fallback);
        assert!(TtsPreferences::app_default(false).secondary.is_none());
        let legacy: TtsPreferences = serde_json::from_str(r#"{"primary":{"engine":"piper","model_id":"pt_BR-faber-medium"},"secondary":{"engine":"system"}}"#).unwrap();
        assert!(!legacy.continues_native());
        assert!(serde_json::to_value(&legacy)
            .unwrap()
            .get("policy_version")
            .is_none());
        assert!(app.effective_selection(None, false).secondary.is_none());
        assert!(app.primary.validate(Some("en-US")).is_err());
    }
    #[test]
    fn incompatible_book_language_can_use_only_versioned_native_continuation() {
        let preferences = TtsPreferences::app_default(true);
        assert!(preferences.validate(Some("en")).is_ok());
        assert!(preferences.primary.validate(Some("en")).is_err());
        let mut legacy = preferences.clone();
        legacy.policy_version = None;
        assert!(legacy.validate(Some("en")).is_err());
        assert!(preferences
            .effective_selection(None, false)
            .validate(Some("en"))
            .is_err());
        assert!(TtsPreferences::app_default(false)
            .validate(Some("en"))
            .is_err());
        let mut malformed = preferences;
        malformed.primary.model_id = Some("../invalid-model".into());
        assert!(malformed.validate(Some("en")).is_err());
    }
    #[test]
    fn native_continuation_is_bounded_resumable_and_cancellation_safe() {
        let preferences = TtsPreferences::app_default(true);
        let mut policy = SegmentPolicy::default();
        assert!(policy.should_try_primary(&preferences));
        policy.provider_failed(false, &preferences).unwrap();
        assert!(policy.should_try_primary(&preferences));
        policy.provider_failed(false, &preferences).unwrap();
        let snapshot = serde_json::to_string(&policy).unwrap();
        assert!(policy.provider_failed(true, &preferences).is_err());
        assert_eq!(snapshot, serde_json::to_string(&policy).unwrap());
        let mut resumed: SegmentPolicy = serde_json::from_str(&snapshot).unwrap();
        assert!(!resumed.should_try_primary(&preferences));
        assert!(resumed.should_try_primary(&preferences));
        resumed.provider_failed(false, &preferences).unwrap();
        resumed.primary_succeeded();
        assert!(resumed.is_initial());
        assert!(resumed.should_try_primary(&preferences));
        let mut unsupported = preferences;
        unsupported.policy_version = Some(9);
        assert!(unsupported.validate(Some("pt-BR")).is_err());
    }
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
