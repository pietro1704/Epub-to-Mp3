//! Saved profile and strict per-job TTS preference selection.
use super::cli_environment::cli_config;
use super::CliOptions;
use std::fs;
use std::path::PathBuf;

pub(super) fn preference_path(config: &converter_core::config::AppConfig) -> PathBuf {
    config.paths.persistent_root.join("tts-preferences.json")
}
pub(super) fn saved_preferences(
    config: &converter_core::config::AppConfig,
) -> Result<converter_core::tts_preferences::TtsPreferences, String> {
    let path = preference_path(config);
    if !path.exists() {
        return Ok(Default::default());
    }
    let bytes = fs::read(path).map_err(|e| e.to_string())?;
    serde_json::from_slice(&bytes).map_err(|e| format!("Invalid saved TTS preferences: {e}"))
}
pub(super) fn command_preferences(raw: &[String]) -> Result<i32, String> {
    let config = cli_config();
    match raw.get(1).map(String::as_str).unwrap_or("show") {
        "show" => println!(
            "{}",
            serde_json::to_string_pretty(&saved_preferences(&config)?).map_err(|e| e.to_string())?
        ),
        "set" => {
            let json = raw.get(2).ok_or("Usage: preferences set JSON")?;
            let preferences: converter_core::tts_preferences::TtsPreferences =
                serde_json::from_str(json).map_err(|e| e.to_string())?;
            preferences.validate(None)?;
            converter_core::cache::atomic_write_json(preference_path(&config), &preferences)
                .map_err(|e| e.to_string())?;
        }
        _ => return Err("Usage: preferences show | preferences set JSON".into()),
    }
    Ok(0)
}
pub(super) fn preferences_with_legacy_engine(
    mut preferences: converter_core::tts_preferences::TtsPreferences,
    engine: Option<&str>,
) -> Result<converter_core::tts_preferences::TtsPreferences, String> {
    let Some(engine) = engine.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(preferences);
    };
    let engine = engine.to_ascii_lowercase();
    if engine == "auto" {
        return Ok(preferences);
    }
    if !matches!(engine.as_str(), "edge" | "piper" | "system") {
        return Err(format!("Invalid ENGINE value: {engine}"));
    }
    if preferences.primary.engine != engine {
        preferences.primary = if engine == "piper" {
            Default::default()
        } else {
            converter_core::tts_preferences::TtsSelection {
                session: None,
                engine,
                model_id: None,
                voice: None,
            }
        };
        preferences.secondary = None;
    }
    Ok(preferences)
}

// Keep CLI snapshots strict without changing persisted preference compatibility.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CapturedTtsSelection {
    engine: String,
    #[serde(default)]
    session: Option<converter_core::tts_session::SessionSelection>,
    model_id: Option<String>,
    voice: Option<String>,
}

impl CapturedTtsSelection {
    fn into_selection(self) -> converter_core::tts_preferences::TtsSelection {
        converter_core::tts_preferences::TtsSelection {
            session: self.session,
            engine: self.engine,
            model_id: self.model_id,
            voice: self.voice,
        }
    }
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CapturedTtsPreferences {
    #[serde(default)]
    policy_version: Option<u8>,
    primary: CapturedTtsSelection,
    secondary: Option<CapturedTtsSelection>,
    allow_online_fallback: bool,
}

pub(super) fn parse_captured_preferences(
    json: &str,
) -> Result<converter_core::tts_preferences::TtsPreferences, String> {
    let captured: CapturedTtsPreferences = serde_json::from_str(json)
        .map_err(|error| format!("Invalid --tts-preferences-json: {error}"))?;
    let preferences = converter_core::tts_preferences::TtsPreferences {
        policy_version: captured.policy_version,
        primary: captured.primary.into_selection(),
        secondary: captured.secondary.map(CapturedTtsSelection::into_selection),
        allow_online_fallback: captured.allow_online_fallback,
    };
    preferences.validate(None)?;
    Ok(preferences)
}

pub(super) fn effective_preferences(
    config: &converter_core::config::AppConfig,
    options: &CliOptions,
    raw: &[String],
) -> Result<converter_core::tts_preferences::TtsPreferences, String> {
    if let Some(captured) = &options.tts_preferences {
        return Ok(captured.clone());
    }
    let legacy_engine = if raw
        .iter()
        .any(|value| matches!(value.as_str(), "--engine" | "--model"))
    {
        None
    } else {
        std::env::var("ENGINE").ok()
    };
    let mut preferences =
        preferences_with_legacy_engine(saved_preferences(config)?, legacy_engine.as_deref())?;
    if raw
        .iter()
        .any(|v| matches!(v.as_str(), "--engine" | "--model" | "--voice"))
        && !raw.iter().any(|v| v == "--use-secondary")
    {
        preferences.secondary = None;
        preferences.policy_version = None;
    }
    if (options.fallback_model.is_some() || options.fallback_voice.is_some())
        && !raw.iter().any(|v| v == "--fallback-engine")
    {
        return Err("--fallback-model and --fallback-voice require --fallback-engine".into());
    }
    if raw.iter().any(|v| v == "--engine") {
        preferences.primary.session = None;
        if preferences.primary.engine != options.engine {
            preferences.primary.voice = None;
        }
        preferences.primary.engine = if options.engine == "auto" {
            "piper".into()
        } else {
            options.engine.clone()
        };
        preferences.primary.model_id = if matches!(options.engine.as_str(), "piper" | "auto") {
            Some(converter_core::tts_preferences::FABER_MODEL_ID.into())
        } else {
            None
        };
    }
    if let Some(model) = &options.model {
        preferences.primary.session = None;
        if preferences.primary.engine != "piper" {
            preferences.primary.voice = None;
        }
        preferences.primary.engine = "piper".into();
        preferences.primary.model_id = Some(model.clone());
        if let Some(descriptor) = converter_core::model_catalog::MODELS
            .iter()
            .find(|descriptor| descriptor.id == model)
        {
            let runtime = converter_core::tts_session::runtime_for(descriptor.engine)
                .ok_or("The model has no registered runtime descriptor")?;
            preferences.primary.engine = descriptor.engine.into();
            preferences.primary.session = Some(converter_core::tts_session::SessionSelection {
                version: 2,
                provider: descriptor.engine.into(),
                runtime: runtime.into(),
                model_id: Some(model.clone()),
                model_revision: Some(
                    descriptor
                        .artifacts
                        .iter()
                        .map(|artifact| artifact.sha256)
                        .collect::<Vec<_>>()
                        .join(":"),
                ),
                voice: options.voice.clone(),
                options: Default::default(),
            });
        }
    }
    if options.voice.is_some() {
        preferences.primary.voice = options.voice.clone();
        if let Some(session) = &mut preferences.primary.session {
            session.voice = options.voice.clone();
        }
    }
    if let Some(id) = &options.fallback_model {
        if options.fallback_engine == "none"
            || options.fallback_engine == "system"
            || options.fallback_engine == "edge"
            || converter_core::model_catalog::MODELS
                .iter()
                .any(|model| model.id == id && model.engine != options.fallback_engine)
        {
            return Err("Fallback model does not belong to the selected fallback engine".into());
        }
    }
    if raw
        .iter()
        .any(|v| v == "--fallback-engine" || v == "--engine-chain-fallback")
    {
        preferences.secondary = match options.fallback_engine.as_str() {
            "none" => None,
            provider
                if options.fallback_model.as_ref().is_some_and(|id| {
                    converter_core::model_catalog::MODELS
                        .iter()
                        .any(|model| model.id == id && model.engine == provider)
                }) =>
            {
                let id = options.fallback_model.as_ref().expect("matched model");
                Some(catalog_model_selection(id, options.fallback_voice.clone())?)
            }
            "edge" | "system" | "piper" => {
                Some(converter_core::tts_preferences::TtsSelection {
                    session: None,
                    engine: options.fallback_engine.clone(),
                    model_id: if options.fallback_engine == "piper" {
                        Some(options.fallback_model.clone().unwrap_or_else(|| {
                            converter_core::tts_preferences::FABER_MODEL_ID.into()
                        }))
                    } else {
                        None
                    },
                    voice: options.fallback_voice.clone(),
                })
            }
            _ => {
                return Err(
                    "Choose an explicit --fallback-engine: none, edge, piper, system".into(),
                )
            }
        };
    }
    if let Some(allow_online_fallback) = options.allow_online_fallback {
        preferences.allow_online_fallback = allow_online_fallback;
    }
    preferences.validate(None)?;
    Ok(preferences)
}

fn catalog_model_selection(
    id: &str,
    voice: Option<String>,
) -> Result<converter_core::tts_preferences::TtsSelection, String> {
    let model = converter_core::model_catalog::MODELS
        .iter()
        .find(|model| model.id == id)
        .ok_or("Unknown fallback model in catalog")?;
    let runtime = converter_core::tts_session::runtime_for(model.engine)
        .ok_or("Model runtime is not registered")?;
    Ok(converter_core::tts_preferences::TtsSelection {
        engine: model.engine.into(),
        model_id: Some(id.into()),
        voice: voice.clone(),
        session: Some(converter_core::tts_session::SessionSelection {
            version: 2,
            provider: model.engine.into(),
            runtime: runtime.into(),
            model_id: Some(id.into()),
            model_revision: Some(
                model
                    .artifacts
                    .iter()
                    .map(|artifact| artifact.sha256)
                    .collect::<Vec<_>>()
                    .join(":"),
            ),
            voice,
            options: Default::default(),
        }),
    })
}
