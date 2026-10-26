use super::*;

#[derive(Deserialize, Default)]
#[serde(default)]
pub(super) struct EmbeddedConversionOptionsV1 {
    pub(super) contract_version: Option<u32>,
    pub(super) recovery_job_id: Option<String>,
    pub(super) pronunciation: converter_core::pronunciation::PronunciationDictionary,
    #[serde(skip)]
    pub(super) audio_chunks: Option<Arc<std::sync::Mutex<AudioChunkQueue>>>,
    pub(super) tts_policy_state: Option<converter_core::tts_preferences::SegmentPolicy>,
    pub(super) tts_preferences: Option<converter_core::tts_preferences::TtsPreferences>,
    pub(super) engine: Option<String>,
    pub(super) voice: Option<String>,
    pub(super) language: Option<String>,
    pub(super) models_root: Option<String>,
    pub(super) model_id: Option<String>,
    pub(super) model_path: Option<String>,
    pub(super) model_config_path: Option<String>,
    pub(super) espeak_data_directory: Option<String>,
}

impl EmbeddedConversionOptionsV1 {
    pub(super) fn validate_contract(&self) -> Result<(), String> {
        self.pronunciation.validate()?;
        if !self.pronunciation.rules.is_empty() && self.tts_preferences.is_none() {
            return Err("Pronunciation requires an explicit captured TTS selection".into());
        }
        let Some(version) = self.contract_version else {
            return Ok(());
        };
        if version != converter_core::tts_session::CONTRACT_VERSION {
            return Err("Unsupported conversion contract version".into());
        }
        let preferences = self
            .tts_preferences
            .as_ref()
            .ok_or("Version 2 requires captured TTS preferences")?;
        preferences.validate(self.language.as_deref())?;
        for selection in std::iter::once(&preferences.primary).chain(preferences.secondary.iter()) {
            let session = converter_core::tts_session::SessionSelection::from_legacy(selection)
                .map_err(|error| error.to_string())?;
            let descriptor = converter_core::tts_session::builtin_descriptors()
                .into_iter()
                .find(|descriptor| {
                    descriptor.provider == session.provider
                        && descriptor.runtime == session.runtime
                        && descriptor
                            .targets
                            .iter()
                            .any(|target| target == std::env::consts::OS)
                })
                .ok_or("Requested runtime adapter is unavailable")?;
            let language = if preferences.continues_native() {
                ""
            } else {
                self.language.as_deref().unwrap_or("")
            };
            session
                .validate(&descriptor, language)
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}

#[no_mangle]
pub unsafe extern "C" fn converter_conversion_options_validate_json_v2(
    options_json: *const c_char,
) -> bool {
    clear_last_error();
    let json = match c_string(options_json, "conversion options") {
        Ok(json) => json,
        Err(error) => return fail(error),
    };
    let options: EmbeddedConversionOptionsV1 = match serde_json::from_str(&json) {
        Ok(options) => options,
        Err(error) => return fail(error.to_string()),
    };
    if options.contract_version != Some(2) {
        return fail("Version 2 contract is required".into());
    }
    match options.validate_contract() {
        Ok(()) => true,
        Err(error) => fail(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn converter_conversion_options_validate_json_v1(
    options_json: *const c_char,
) -> bool {
    clear_last_error();
    let json = match c_string(options_json, "conversion options") {
        Ok(json) => json,
        Err(error) => return fail(error),
    };
    let options = match serde_json::from_str::<EmbeddedConversionOptionsV1>(&json) {
        Ok(options) => options,
        Err(error) => return fail(format!("invalid conversion options: {error}")),
    };
    let mut options = options;
    if let Some(preferences) = &options.tts_preferences {
        if let Err(error) = preferences.validate(options.language.as_deref()) {
            return fail(error);
        }
        options.engine = Some(preferences.primary.engine.clone());
        options.voice = preferences.primary.voice.clone();
        options.model_id = preferences.primary.model_id.clone();
    }
    let engine = options
        .engine
        .as_deref()
        .unwrap_or("edge")
        .to_ascii_lowercase();
    if !matches!(engine.as_str(), "edge" | "piper" | "system") {
        return fail(format!("unsupported conversion engine: {engine}"));
    }
    if options
        .language
        .as_deref()
        .is_some_and(|value| value.chars().any(char::is_control))
    {
        return fail("language contains control characters".to_owned());
    }
    if engine == "piper" {
        if (options.models_root.is_none()
            && !options
                .tts_preferences
                .as_ref()
                .is_some_and(|p| p.continues_native()))
            || options.model_id.is_none()
        {
            return fail("Piper requires an explicitly installed local model.".to_owned());
        }
        if let Err(error) = resolve_piper_model_paths(&options) {
            return fail(error);
        }
    } else if options.model_id.is_some()
        || options.model_path.is_some()
        || options.model_config_path.is_some()
    {
        return fail("Piper model configuration cannot be used with Edge.".to_owned());
    }
    true
}

pub(super) fn embedded_engine_from_value(value: Option<&str>) -> String {
    match value
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "piper" => "piper".to_owned(),
        "system" => "system".to_owned(),
        _ => "edge".to_owned(),
    }
}

pub(super) fn resolve_piper_model_paths(
    options: &EmbeddedConversionOptionsV1,
) -> Result<(std::path::PathBuf, std::path::PathBuf), String> {
    let Some(model_id) = options.model_id.as_deref() else {
        return Err("Piper requires an explicitly installed local model.".to_owned());
    };
    // Validation may run before the session supplies its managed model root.
    // Actual conversion fills that root from AppConfig before resolving paths.
    let root = match options.models_root.as_deref() {
        Some(root) => root,
        None if options
            .tts_preferences
            .as_ref()
            .is_some_and(|p| p.continues_native()) =>
        {
            "."
        }
        None => return Err("Piper requires an explicitly installed local model.".into()),
    };
    for value in [
        model_id,
        options.model_path.as_deref().unwrap_or("model.onnx"),
        options
            .model_config_path
            .as_deref()
            .unwrap_or("model.onnx.json"),
    ] {
        if value.is_empty()
            || Path::new(value)
                .components()
                .any(|component| !matches!(component, std::path::Component::Normal(_)))
            || value.contains(char::from(92))
        {
            return Err(
                "Piper model paths must remain inside the installed model directory".into(),
            );
        }
    }
    if Path::new(model_id).components().count() != 1 {
        return Err("Invalid Piper model ID".into());
    }
    let model = Path::new(root)
        .join(model_id)
        .join(options.model_path.as_deref().unwrap_or("model.onnx"));
    let config = model.with_file_name(
        options
            .model_config_path
            .as_deref()
            .unwrap_or("model.onnx.json"),
    );
    if (!model.is_file() || !config.is_file())
        && !options
            .tts_preferences
            .as_ref()
            .is_some_and(|p| p.continues_native())
    {
        return Err(format!(
            "Piper model or voice config is not installed: {}",
            model.display()
        ));
    }
    Ok((model, config))
}
