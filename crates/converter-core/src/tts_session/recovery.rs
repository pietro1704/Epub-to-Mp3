//! Transactional recovery: commit only after validated audio is accepted.
use super::{FailureKind, TtsFailure};
use crate::tts_preferences::{SegmentPolicy, TtsPreferences, TtsSelection};

#[derive(Clone)]
pub struct RecoveryAttempt {
    policy: SegmentPolicy,
    preferences: TtsPreferences,
    selection: TtsSelection,
    stage: u8,
    installed_system: bool,
}
impl RecoveryAttempt {
    pub fn new(
        policy: &SegmentPolicy,
        preferences: &TtsPreferences,
        installed_system: bool,
    ) -> Result<Self, TtsFailure> {
        let mut attempt = Self {
            policy: policy.clone(),
            preferences: preferences.clone(),
            selection: preferences.primary.clone(),
            stage: 0,
            installed_system,
        };
        if !attempt.policy.should_try_primary(preferences) {
            attempt.advance(None)?;
        }
        Ok(attempt)
    }
    pub fn selection(&self) -> &TtsSelection {
        &self.selection
    }
    pub fn fallback_used(&self) -> bool {
        self.stage != 0
    }
    pub fn failed(&mut self, failure: &TtsFailure) -> Result<(), TtsFailure> {
        if failure.terminal() {
            return Err(failure.clone());
        }
        if self.stage == 0 {
            self.policy
                .provider_failed(false, &self.preferences)
                .map_err(|message| {
                    TtsFailure::new(failure.kind, format!("{message}: {failure}"))
                })?;
            if self.preferences.continues_native() {
                if let Some(delay) = failure.retry_after_ms {
                    self.policy
                        .defer_primary_for(std::time::Duration::from_millis(delay));
                }
            }
        } else if self.stage == 1 && self.preferences.continues_native() {
            if let Some(delay) = failure.retry_after_ms {
                self.policy
                    .defer_secondary_for(std::time::Duration::from_millis(delay));
            }
        }
        self.advance(Some(failure))
    }
    fn advance(&mut self, failure: Option<&TtsFailure>) -> Result<(), TtsFailure> {
        if self.stage == 0 {
            if let Some(secondary) = &self.preferences.secondary {
                if self.policy.should_try_secondary() {
                    self.selection = secondary.clone();
                    self.stage = 1;
                    return Ok(());
                }
            }
            self.stage = 1;
        }
        if self.stage == 1
            && self.installed_system
            && self.preferences.continues_native()
            && self.preferences.primary.engine != "system"
            && self
                .preferences
                .secondary
                .as_ref()
                .is_none_or(|selection| selection.engine != "system")
        {
            self.selection = TtsSelection {
                session: None,
                engine: "system".into(),
                model_id: None,
                voice: None,
            };
            self.stage = 2;
            return Ok(());
        }
        Err(failure.cloned().unwrap_or_else(|| {
            TtsFailure::new(
                FailureKind::Unavailable,
                "No provider is ready during recovery cooldown",
            )
        }))
    }
    pub fn accepted(mut self) -> SegmentPolicy {
        if self.stage == 0 {
            self.policy.primary_succeeded();
        }
        if self.stage == 1 {
            self.policy.secondary_succeeded();
        }
        self.policy
    }
}
