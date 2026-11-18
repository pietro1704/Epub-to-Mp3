//! Capture legacy request fields once, before execution or persisted-job mutation.
use super::{ConversionRequest, ConversionWorker, WorkerError};
use crate::tts_preferences::TtsPreferences;

impl ConversionWorker {
    pub(super) fn capture_request_preferences(
        &self,
        mut request: ConversionRequest,
    ) -> Result<ConversionRequest, WorkerError> {
        if request.tts_preferences.is_none() {
            let model_id = (request.piper_model.is_some() || request.piper_config.is_some())
                .then(|| {
                    request.piper_model.as_deref().and_then(|path| {
                        let stem = path.file_stem()?;
                        if stem == "model" {
                            path.parent().and_then(|parent| parent.file_name()).or(Some(stem))
                        } else { Some(stem) }
                    }).and_then(|name| name.to_str()).unwrap_or(crate::tts_preferences::FABER_MODEL_ID)
                });
            request.tts_preferences = Some(TtsPreferences::capture_legacy_selection(
                request.engine.as_deref().or(Some(&self.config.engine)),
                request.voice.as_deref(), model_id, self.platform_tts.is_some(),
            ).map_err(WorkerError::Unsupported)?);
        }
        request
            .tts_preferences
            .as_ref()
            .expect("captured preferences")
            .validate(None)
            .map_err(WorkerError::Unsupported)?;
        Ok(request)
    }
}
