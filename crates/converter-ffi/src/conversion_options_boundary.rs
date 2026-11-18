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
    pub(super) language_overrides: Vec<converter_core::language::LanguageOverride>,
    pub(super) models_root: Option<String>,
    pub(super) model_id: Option<String>,
    pub(super) model_path: Option<String>,
    pub(super) model_config_path: Option<String>,
    pub(super) espeak_data_directory: Option<String>,
}

impl EmbeddedConversionOptionsV1 {
    pub(super) fn selection_input(
        &self,
    ) -> converter_core::conversion_selection::ConversionSelectionInput<'_> {
        converter_core::conversion_selection::ConversionSelectionInput {
            preferences: self.tts_preferences.as_ref(),
            engine: self.engine.as_deref(),
            voice: self.voice.as_deref(),
            model_id: self.model_id.as_deref(),
            language: self.language.as_deref(),
            models_root: self.models_root.as_deref(),
            model_path: self.model_path.as_deref(),
            model_config_path: self.model_config_path.as_deref(),
        }
    }

    pub(super) fn capture_preferences(&mut self, edge_system_fallback: bool) -> Result<(), String> {
        self.tts_preferences = Some(self.selection_input().capture(edge_system_fallback)?);
        let preferences = self.tts_preferences.as_ref().expect("captured preferences");
        self.engine = Some(preferences.primary.engine.clone());
        self.voice = preferences.primary.voice.clone();
        self.model_id = preferences.primary.model_id.clone();
        Ok(())
    }

    pub(super) fn validate_contract(&self) -> Result<(), String> {
        self.pronunciation.validate()?;
        for correction in &self.language_overrides {
            correction.validate()?;
        }
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
    ffi_guard(
        "converter_conversion_options_validate_json_v2",
        false,
        || {
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
        },
    )
}

#[no_mangle]
pub unsafe extern "C" fn converter_conversion_options_validate_json_v1(
    options_json: *const c_char,
) -> bool {
    ffi_guard(
        "converter_conversion_options_validate_json_v1",
        false,
        || {
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
            if let Err(error) = options.capture_preferences(false) {
                return fail(error);
            }
            let engine = options
                .engine
                .as_deref()
                .expect("captured primary provider");
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
        },
    )
}

pub(super) fn resolve_piper_model_paths(
    options: &EmbeddedConversionOptionsV1,
) -> Result<(std::path::PathBuf, std::path::PathBuf), String> {
    converter_core::conversion_selection::InstalledPiperSelection {
        root: options.models_root.as_deref().map(Path::new),
        model_id: options.model_id.as_deref(),
        model_path: options.model_path.as_deref(),
        config_path: options.model_config_path.as_deref(),
    }
    .resolve(
        options
            .tts_preferences
            .as_ref()
            .is_some_and(|p| p.continues_native()),
    )
}

#[cfg(test)]
mod language_correction_tests {
    use super::EmbeddedConversionOptionsV1;

    #[test]
    fn language_overrides_cross_the_boundary_with_source_coordinates() {
        let options: EmbeddedConversionOptionsV1 = serde_json::from_str(
            r#"{"language_overrides":[{"chapter_index":3,"start":12,"end":80,"language":"pt-PT"}]}"#,
        ).unwrap();
        options.validate_contract().unwrap();
        assert_eq!(options.language_overrides[0].chapter_index, 3);
        assert_eq!(options.language_overrides[0].language, "pt-PT");
        assert!(serde_json::from_str::<EmbeddedConversionOptionsV1>(
            r#"{"language_overrides":[{"chapter_index":-1,"start":12,"end":80,"language":"en"}]}"#,
        )
        .is_err());
        let invalid: EmbeddedConversionOptionsV1 = serde_json::from_str(
            r#"{"language_overrides":[{"chapter_index":0,"start":80,"end":12,"language":"en"}]}"#,
        )
        .unwrap();
        assert!(invalid.validate_contract().is_err());
    }
}
