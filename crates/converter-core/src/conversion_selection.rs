//! Capture embedded conversion choices and resolve installed model paths in core.
use crate::tts_preferences::TtsPreferences;
use std::path::{Component, Path, PathBuf};

#[derive(Default)]
pub struct ConversionSelectionInput<'a> {
    pub preferences: Option<&'a TtsPreferences>,
    pub engine: Option<&'a str>,
    pub voice: Option<&'a str>,
    pub model_id: Option<&'a str>,
    pub language: Option<&'a str>,
    pub models_root: Option<&'a str>,
    pub model_path: Option<&'a str>,
    pub model_config_path: Option<&'a str>,
}

pub struct ResolvedConversionSelection {
    pub preferences: TtsPreferences,
    pub models_root: Option<PathBuf>,
    pub piper_model: Option<PathBuf>,
    pub piper_config: Option<PathBuf>,
}

impl ConversionSelectionInput<'_> {
    pub fn capture(&self, edge_system_fallback: bool) -> Result<TtsPreferences, String> {
        let preferences = match self.preferences {
            Some(preferences) => preferences.clone(),
            None => TtsPreferences::capture_legacy_selection(
                self.engine,
                self.voice,
                self.model_id,
                edge_system_fallback,
            )?,
        };
        preferences.validate(self.language)?;
        Ok(preferences)
    }

    pub fn resolve(
        &self,
        default_model_root: &Path,
        edge_system_fallback: bool,
    ) -> Result<ResolvedConversionSelection, String> {
        let preferences = self.capture(edge_system_fallback)?;
        let models_root = self.models_root.map(PathBuf::from).or_else(|| {
            preferences
                .continues_native()
                .then(|| default_model_root.to_owned())
        });
        let piper = std::iter::once(&preferences.primary)
            .chain(preferences.secondary.iter())
            .find(|selection| selection.engine == "piper");
        let (piper_model, piper_config) = match piper {
            Some(selection) => {
                let paths = InstalledPiperSelection {
                    root: models_root.as_deref(),
                    model_id: selection.model_id.as_deref(),
                    model_path: self.model_path,
                    config_path: self.model_config_path,
                }
                .resolve(preferences.continues_native())?;
                (Some(paths.0), Some(paths.1))
            }
            None => (None, None),
        };
        Ok(ResolvedConversionSelection {
            preferences,
            models_root,
            piper_model,
            piper_config,
        })
    }
}

/// Relative artifacts in one installed model namespace. CLI absolute paths are
/// a separate explicit contract and do not pass through this embedded boundary.
pub struct InstalledPiperSelection<'a> {
    pub root: Option<&'a Path>,
    pub model_id: Option<&'a str>,
    pub model_path: Option<&'a str>,
    pub config_path: Option<&'a str>,
}

impl InstalledPiperSelection<'_> {
    pub fn resolve(&self, allow_missing: bool) -> Result<(PathBuf, PathBuf), String> {
        let model_id = self
            .model_id
            .ok_or("Piper requires an explicitly installed local model.")?;
        // Validation can precede the session's managed model-root capture.
        let root = match self.root {
            Some(root) => root,
            None if allow_missing => Path::new("."),
            None => return Err("Piper requires an explicitly installed local model.".into()),
        };
        let model_path = self.model_path.unwrap_or("model.onnx");
        let config_path = self.config_path.unwrap_or("model.onnx.json");
        for value in [model_id, model_path, config_path] {
            if value.is_empty()
                || Path::new(value)
                    .components()
                    .any(|part| !matches!(part, Component::Normal(_)))
                || value.contains('\\')
            {
                return Err(
                    "Piper model paths must remain inside the installed model directory".into(),
                );
            }
        }
        if Path::new(model_id).components().count() != 1 {
            return Err("Invalid Piper model ID".into());
        }
        let model = root.join(model_id).join(model_path);
        let config = model.with_file_name(config_path);
        if (!model.is_file() || !config.is_file()) && !allow_missing {
            return Err(format!(
                "Piper model or voice config is not installed: {}",
                model.display()
            ));
        }
        Ok((model, config))
    }
}

#[cfg(test)]
mod tests;
