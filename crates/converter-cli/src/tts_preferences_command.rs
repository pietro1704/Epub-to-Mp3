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
    model_id: Option<String>,
    voice: Option<String>,
}

impl CapturedTtsSelection {
    fn into_selection(self) -> converter_core::tts_preferences::TtsSelection {
        converter_core::tts_preferences::TtsSelection {
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
    }
    if (options.fallback_model.is_some() || options.fallback_voice.is_some())
        && !raw.iter().any(|v| v == "--fallback-engine")
    {
        return Err("--fallback-model and --fallback-voice require --fallback-engine".into());
    }
    if raw.iter().any(|v| v == "--engine") {
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
        if preferences.primary.engine != "piper" {
            preferences.primary.voice = None;
        }
        preferences.primary.engine = "piper".into();
        preferences.primary.model_id = Some(model.clone());
    }
    if options.voice.is_some() {
        preferences.primary.voice = options.voice.clone();
    }
    if raw
        .iter()
        .any(|v| v == "--fallback-engine" || v == "--engine-chain-fallback")
    {
        preferences.secondary = match options.fallback_engine.as_str() {
            "none" => None,
            "edge" | "system" | "piper" => {
                Some(converter_core::tts_preferences::TtsSelection {
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
