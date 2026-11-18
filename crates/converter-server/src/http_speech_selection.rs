//! Capture HTTP speech selections through the core boundary shared with FFI and CLI.
use super::http_model_routes::installable_model;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use converter_core::config::AppConfig;
use converter_core::conversion_selection::{ConversionSelectionInput, ResolvedConversionSelection};
use converter_core::tts_preferences::{TtsPreferences, TtsSelection};
use converter_core::worker::ConversionRequest;
use std::path::{Component, Path, PathBuf};

/// Voice fields supplied by a client or retained by a persisted job.
pub(super) struct SpeechSelection<'a> {
    pub(super) preferences: Option<&'a TtsPreferences>,
    pub(super) engine: Option<&'a str>,
    pub(super) voice: Option<&'a str>,
    pub(super) language: Option<&'a str>,
}

#[derive(Debug)]
pub(super) struct SelectionError {
    status: StatusCode,
    detail: String,
}

impl IntoResponse for SelectionError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(serde_json::json!({"detail": self.detail})),
        )
            .into_response()
    }
}

impl SelectionError {
    fn unprocessable(detail: String) -> Self {
        Self {
            status: StatusCode::UNPROCESSABLE_ENTITY,
            detail,
        }
    }
}

/// A captured selection and the catalog voices to install before it can run.
pub(super) struct SelectionPlan {
    pub(super) preferences: TtsPreferences,
    pub(super) missing_models: Vec<&'static str>,
    language: Option<String>,
}

fn models_root(config: &AppConfig) -> PathBuf {
    config.paths.models_dir.join("tts")
}

/// The Piper model a selection names, when its artifacts are absent from the
/// server's model store. Conversion requires the same two files.
fn missing_piper_model<'a>(voice: &'a TtsSelection, models_root: &Path) -> Option<&'a str> {
    if voice.engine != "piper" {
        return None;
    }
    let model_id = voice.model_id.as_deref()?;
    let mut parts = Path::new(model_id).components();
    // Core rejects anything else with its own message; never probe such a path.
    if !matches!(
        (parts.next(), parts.next()),
        (Some(Component::Normal(_)), None)
    ) {
        return None;
    }
    let directory = models_root.join(model_id);
    let installed =
        directory.join("model.onnx").is_file() && directory.join("model.onnx.json").is_file();
    (!installed).then_some(model_id)
}

impl SpeechSelection<'_> {
    /// Typed preferences win; legacy `engine`/`voice` fields are captured once.
    /// A malformed selection is the client's error.
    ///
    /// Owner decision of 2026-11-18 for this server: a conversion whose Piper
    /// voice is absent installs that catalog voice on demand, because a hosted
    /// instance may restart with an empty disk. Only a selection that could
    /// never synthesize here is refused: this process has no host speech
    /// adapter, so `system` cannot run, and a voice outside the installable
    /// catalog cannot be fetched.
    pub(super) fn plan(&self, config: &AppConfig) -> Result<SelectionPlan, SelectionError> {
        let models_root = models_root(config);
        let models_root_text = models_root.to_string_lossy();
        let input = ConversionSelectionInput {
            preferences: self.preferences,
            engine: self.engine.or(Some(config.engine.as_str())),
            voice: self.voice,
            language: self.language,
            models_root: Some(&models_root_text),
            ..Default::default()
        };
        // No host speech adapter exists here, so a legacy Edge primary gains no
        // implicit system secondary.
        let preferences = input.capture(false).map_err(|detail| SelectionError {
            status: StatusCode::BAD_REQUEST,
            detail,
        })?;
        let voices = || std::iter::once(&preferences.primary).chain(preferences.secondary.iter());
        let mut missing_models = Vec::new();
        for model_id in voices().filter_map(|voice| missing_piper_model(voice, &models_root)) {
            let Some(model) = installable_model(model_id) else {
                return Err(SelectionError::unprocessable(format!(
                    "Piper model {model_id} is not installed on this server and cannot be \
                     downloaded from its catalog."
                )));
            };
            if !missing_models.contains(&model.id) {
                missing_models.push(model.id);
            }
        }
        if !voices().any(|voice| matches!(voice.engine.as_str(), "piper" | "edge")) {
            return Err(SelectionError::unprocessable(
                "This server has no system speech adapter. Select a Piper voice or explicitly \
                 select Edge."
                    .into(),
            ));
        }
        Ok(SelectionPlan {
            preferences,
            missing_models,
            language: self.language.map(str::to_owned),
        })
    }
}

impl SelectionPlan {
    /// Resolve installed model paths once every planned voice is present.
    pub(super) fn resolve(
        &self,
        config: &AppConfig,
    ) -> Result<ResolvedConversionSelection, String> {
        let models_root = models_root(config);
        let models_root_text = models_root.to_string_lossy();
        ConversionSelectionInput {
            preferences: Some(&self.preferences),
            language: self.language.as_deref(),
            models_root: Some(&models_root_text),
            ..Default::default()
        }
        .resolve(&models_root, false)
    }
}

pub(super) fn conversion_request(
    selection: ResolvedConversionSelection,
    input: PathBuf,
    job_id: String,
    language: Option<String>,
    no_parallel: bool,
) -> ConversionRequest {
    ConversionRequest {
        input,
        job_id,
        engine: Some(selection.preferences.primary.engine.clone()),
        voice: selection.preferences.primary.voice.clone(),
        language,
        piper_model: selection.piper_model,
        piper_config: selection.piper_config,
        tts_preferences: Some(selection.preferences),
        models_root: selection.models_root,
        chapter_indices: None,
        no_parallel,
    }
}
