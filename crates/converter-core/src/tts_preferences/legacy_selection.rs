//! One-time capture of legacy provider fields at input/persistence boundaries.
use super::{TtsPreferences, TtsSelection, FABER_MODEL_ID};

impl TtsPreferences {
    pub fn capture_legacy_selection(
        engine: Option<&str>,
        voice: Option<&str>,
        model_id: Option<&str>,
        edge_system_fallback: bool,
    ) -> Result<Self, String> {
        let engine = engine.unwrap_or("auto").trim().to_ascii_lowercase();
        if matches!(engine.as_str(), "" | "auto") && model_id.is_none() {
            return Ok(Self::app_default(true));
        }
        let engine = match engine.as_str() {
            "" | "auto" | "piper" => "piper",
            "system" => "system",
            "edge" => "edge",
            _ => return Err(format!("Unsupported conversion engine: {engine}")),
        };
        if engine != "piper" && model_id.is_some() {
            return Err("Only Piper selections accept a local model ID".into());
        }
        let preferences = Self {
            primary: TtsSelection {
                engine: engine.into(),
                model_id: (engine == "piper").then(|| model_id.unwrap_or(FABER_MODEL_ID).into()),
                voice: voice.map(str::to_owned),
                session: None,
            },
            // Preserve occasional native recovery only for an explicitly selected
            // legacy Edge primary with an installed adapter. This grants no online fallback.
            secondary: (engine == "edge" && edge_system_fallback).then(|| TtsSelection {
                engine: "system".into(),
                model_id: None,
                voice: None,
                session: None,
            }),
            // A legacy job that names Edge as its engine is itself the explicit
            // online choice; typed preferences must carry the consent instead.
            allow_online_fallback: engine == "edge",
            ..Self::default()
        };
        preferences.validate(None)?;
        Ok(preferences)
    }
}
