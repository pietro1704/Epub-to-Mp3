use super::{ConversionRequest, ConversionWorker};
use std::path::PathBuf;

impl ConversionWorker {
    pub(super) fn selection_model_paths(
        &self,
        request: &ConversionRequest,
        selection: &crate::tts_preferences::TtsSelection,
    ) -> (PathBuf, PathBuf) {
        let id = selection
            .model_id
            .as_deref()
            .unwrap_or(crate::tts_preferences::FABER_MODEL_ID);
        let explicit_selection = request.tts_preferences.as_ref().and_then(|preferences| {
            std::iter::once(&preferences.primary)
                .chain(preferences.secondary.iter())
                .find(|candidate| candidate.engine == "piper")
        });
        let explicit_applies = selection.engine == "piper"
            && explicit_selection.is_none_or(|candidate| candidate.model_id == selection.model_id);
        let model = if explicit_applies && request.piper_model.is_some() {
            request.piper_model.clone().expect("explicit model")
        } else if let Some(root) = &request.models_root {
            root.join(id).join("model.onnx")
        } else {
            self.config
                .paths
                .piper_models_dir
                .join(format!("{id}.onnx"))
        };
        let config = if explicit_applies && request.piper_config.is_some() {
            request.piper_config.clone().expect("explicit config")
        } else if let Some(root) = &request.models_root {
            root.join(id).join("model.onnx.json")
        } else {
            model.with_extension("onnx.json")
        };
        (model, config)
    }
}
