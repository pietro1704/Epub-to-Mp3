use super::*;
use crate::tts_preferences::TtsSelection;

pub fn runtime_for(provider: &str) -> Option<&'static str> {
    match provider {
        "piper" => Some(if cfg!(target_arch = "wasm32") {
            "piper-web"
        } else {
            "piper"
        }),
        "edge" => Some("edge-websocket"),
        "system" => Some(if cfg!(target_arch = "wasm32") {
            "web-speech"
        } else {
            "platform-speech"
        }),
        "kokoro" => Some("kokoro"),
        _ => None,
    }
}
impl SessionSelection {
    pub fn from_legacy(selection: &TtsSelection) -> Result<Self, TtsFailure> {
        if let Some(session) = &selection.session {
            selection
                .validate(None)
                .map_err(|message| TtsFailure::new(FailureKind::InvalidSelection, message))?;
            return Ok(session.clone());
        }
        let runtime = runtime_for(&selection.engine).ok_or_else(|| {
            TtsFailure::new(
                FailureKind::InvalidSelection,
                format!("Unsupported provider: {}", selection.engine),
            )
        })?;
        Ok(Self {
            version: CONTRACT_VERSION,
            provider: selection.engine.clone(),
            runtime: runtime.into(),
            model_id: selection.model_id.clone(),
            model_revision: None,
            voice: selection.voice.clone(),
            options: BTreeMap::new(),
        })
    }
    pub fn validate(
        &self,
        descriptor: &ProviderDescriptor,
        language: &str,
    ) -> Result<(), TtsFailure> {
        let invalid = |message| TtsFailure::new(FailureKind::InvalidSelection, message);
        if self.provider == "piper" {
            crate::model_catalog::validate_piper_quality(
                self.model_id.as_deref().unwrap_or_default(),
            )
            .map_err(|message| TtsFailure::new(FailureKind::InvalidSelection, message))?;
        }
        if self.version != CONTRACT_VERSION
            || self.provider != descriptor.provider
            || self.runtime != descriptor.runtime
        {
            return Err(invalid("Unsupported synthesis contract or runtime"));
        }
        if self
            .options
            .keys()
            .any(|key| !descriptor.capabilities.configurable_options.contains(key))
        {
            return Err(invalid("This adapter does not accept synthesis options"));
        }
        if !descriptor.capabilities.audio_bytes {
            return Err(invalid("This runtime supports listening only"));
        }
        let language_code = language
            .split(['-', '_'])
            .next()
            .unwrap_or(language)
            .to_ascii_lowercase();
        if !language.is_empty()
            && !descriptor.capabilities.languages.is_empty()
            && !descriptor.capabilities.languages.iter().any(|value| {
                value.eq_ignore_ascii_case(language) || value.eq_ignore_ascii_case(&language_code)
            })
        {
            return Err(invalid("Language is unavailable in this runtime"));
        }
        if let Some(voice) = &self.voice {
            if !descriptor.capabilities.voice_selection {
                return Err(invalid(
                    "This runtime does not accept an explicit voice selection",
                ));
            }
            if !descriptor.capabilities.voices.is_empty()
                && !descriptor.capabilities.voices.contains(voice)
            {
                return Err(invalid("Voice is unavailable in this runtime"));
            }
        }
        if let Some(id) = &self.model_id {
            let model = crate::model_catalog::MODELS
                .iter()
                .find(|model| model.id == id && model.engine == self.provider)
                .ok_or_else(|| invalid("Unknown model/provider selection"))?;
            let code = language
                .split(['-', '_'])
                .next()
                .unwrap_or(language)
                .to_ascii_lowercase();
            if !language.is_empty() && !model.languages.iter().any(|value| *value == code) {
                return Err(invalid("Model does not support this language"));
            }
            if let Some(revision) = &self.model_revision {
                if crate::model_catalog::model_revision(model).as_ref() != Some(revision) {
                    return Err(invalid(
                        "Model revision does not match its catalog manifest",
                    ));
                }
            }
        } else if crate::model_catalog::MODELS
            .iter()
            .any(|model| model.engine == self.provider)
        {
            return Err(invalid("This provider requires an installed model"));
        }
        Ok(())
    }
}

pub fn builtin_descriptors() -> Vec<ProviderDescriptor> {
    let mut descriptors: Vec<_> = [
        ("piper", "piper", AudioFormat::WavPcm16, false),
        ("edge", "edge-websocket", AudioFormat::Mp3, true),
        ("system", "platform-speech", AudioFormat::WavPcm16, false),
        ("kokoro", "kokoro", AudioFormat::WavPcm16, false),
    ]
    .into_iter()
    .map(|(provider, runtime, format, online)| ProviderDescriptor {
        provider: provider.into(),
        runtime: runtime.into(),
        revision: env!("CARGO_PKG_VERSION").into(),
        targets: vec![
            "ios".into(),
            "macos".into(),
            "android".into(),
            "linux".into(),
            "windows".into(),
        ],
        capabilities: TtsCapabilities {
            audio_formats: vec![format],
            languages: Vec::new(),
            voices: Vec::new(),
            voice_selection: provider == "edge",
            configurable_options: Vec::new(),
            max_text_chars: 800,
            cancellation: if provider == "edge" || provider == "system" {
                CancellationCapability::Cooperative
            } else {
                CancellationCapability::AfterCall
            },
            streaming: false,
            audio_bytes: true,
            online,
        },
    })
    .collect();
    let mut browser = descriptors[0].clone();
    browser.runtime = "piper-web".into();
    browser.revision = "piper-web/2;phonemize/1.0.0;ort/1.30.0".into();
    browser.targets = vec!["web".into()];
    browser.capabilities.audio_formats = vec![AudioFormat::Mp3];
    browser.capabilities.voice_selection = true;
    browser.capabilities.cancellation = CancellationCapability::TerminateWorker;
    descriptors.push(browser);
    let mut listening = descriptors[2].clone();
    listening.runtime = "web-speech".into();
    listening.targets = vec!["web".into()];
    listening.capabilities.audio_bytes = false;
    listening.capabilities.audio_formats.clear();
    descriptors.push(listening);
    descriptors
}

pub fn catalog_json() -> String {
    let models: Vec<_> = crate::model_catalog::MODELS
        .iter()
        .map(|model| {
            let mut descriptor = serde_json::to_value(model).expect("model descriptor");
            descriptor["runtime"] = serde_json::json!(runtime_for(model.engine));
            descriptor["revision"] =
                serde_json::json!(crate::model_catalog::model_revision(model).unwrap_or_default());
            descriptor
        })
        .collect();
    serde_json::json!({ "version": CONTRACT_VERSION, "default_selection": SessionSelection::from_legacy(&TtsSelection::default()).expect("default selection"),
        "providers": builtin_descriptors(), "models": models }).to_string()
}
