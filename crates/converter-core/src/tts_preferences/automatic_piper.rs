use super::{TtsPreferences, TtsSelection, AUTOMATIC_PIPER_MODEL_ID};

impl TtsPreferences {
    /// Resolve only the automatic primary after Rust has examined the source.
    /// Prefer an installed eligible voice; keep the recommended Piper voice as
    /// primary when none are installed so the usual recovery policy can report it.
    pub(crate) fn resolve_automatic_piper(
        &self,
        language: Option<&str>,
        is_installed: impl Fn(&TtsSelection) -> bool,
    ) -> Option<Self> {
        if self.primary.engine != "piper"
            || self.primary.model_id.as_deref() != Some(AUTOMATIC_PIPER_MODEL_ID)
        {
            return None;
        }
        let choices = language
            .map(crate::model_catalog::automatic_piper_models)
            .unwrap_or_default();
        let mut candidates = choices.into_iter().map(|model| TtsSelection {
            session: None,
            engine: model.engine.into(),
            model_id: Some(model.id.into()),
            voice: None,
        });
        let primary = if let Some(recommended) = candidates.next() {
            if is_installed(&recommended) {
                recommended
            } else {
                candidates.find(is_installed).unwrap_or(recommended)
            }
        } else {
            self.secondary.clone().or_else(|| {
                self.permits_automatic_system_voice().then(|| TtsSelection {
                    session: None,
                    engine: "system".into(),
                    model_id: None,
                    voice: None,
                })
            })?
        };
        let secondary = self
            .secondary
            .clone()
            .filter(|selection| !selection.same_request(&primary));
        Some(Self {
            primary,
            secondary,
            ..self.clone()
        })
    }
}
