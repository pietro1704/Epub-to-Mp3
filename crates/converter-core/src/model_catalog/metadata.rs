use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LanguageValidation {
    ArtifactDeclared,
    RuntimeValidated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ExactLanguageDescriptor {
    pub tag: &'static str,
    pub frontend: Option<&'static str>,
    pub validation: LanguageValidation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QualityTier {
    Low,
    Medium,
    High,
    Unspecified,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct VoiceDescriptor {
    pub voice_id: Option<&'static str>,
    pub name: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ModelPresentationDescriptor {
    pub model_name: &'static str,
    pub family_name: &'static str,
    pub quality: QualityTier,
    pub voice_choices: &'static [VoiceDescriptor],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LicenceCategory {
    Dataset,
    ModelWeights,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LicenceValidation {
    Partial,
    CreatorDeclared,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct LicenceDescriptor {
    pub id: Option<&'static str>,
    pub category: LicenceCategory,
    pub evidence_url: Option<&'static str>,
    pub terms_fingerprint: Option<&'static str>,
    pub requires_acceptance: bool,
    pub validation: LicenceValidation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ModelMetadata {
    pub presentation: ModelPresentationDescriptor,
    pub exact_languages: &'static [ExactLanguageDescriptor],
    pub licence: LicenceDescriptor,
}

const UNKNOWN_LICENCE: LicenceDescriptor = LicenceDescriptor {
    id: None,
    category: LicenceCategory::Unknown,
    evidence_url: None,
    terms_fingerprint: None,
    requires_acceptance: false,
    validation: LicenceValidation::Unknown,
};

static FABER_VOICES: &[VoiceDescriptor] = &[VoiceDescriptor {
    voice_id: None,
    name: "Faber",
}];
static EDRESSON_VOICES: &[VoiceDescriptor] = &[VoiceDescriptor {
    voice_id: None,
    name: "Edresson",
}];
static LESSAC_VOICES: &[VoiceDescriptor] = &[VoiceDescriptor {
    voice_id: None,
    name: "Lessac",
}];

static PIPER_FABER_LANGUAGES: &[ExactLanguageDescriptor] = &[ExactLanguageDescriptor {
    tag: "pt-BR",
    frontend: Some("espeak-ng:pt-br"),
    validation: LanguageValidation::RuntimeValidated,
}];
static PIPER_EDRESSON_LANGUAGES: &[ExactLanguageDescriptor] = &[ExactLanguageDescriptor {
    tag: "pt-BR",
    frontend: Some("espeak-ng:pt-br"),
    validation: LanguageValidation::ArtifactDeclared,
}];
static PIPER_LESSAC_LANGUAGES: &[ExactLanguageDescriptor] = &[ExactLanguageDescriptor {
    tag: "en-US",
    frontend: Some("espeak-ng:en-us"),
    validation: LanguageValidation::ArtifactDeclared,
}];
static KOKORO_LANGUAGES: &[ExactLanguageDescriptor] = &[ExactLanguageDescriptor {
    tag: "en",
    frontend: None,
    validation: LanguageValidation::ArtifactDeclared,
}];

pub(super) static PIPER_FABER_METADATA: ModelMetadata = ModelMetadata {
    presentation: ModelPresentationDescriptor {
        model_name: "Faber",
        family_name: "Piper",
        quality: QualityTier::Medium,
        voice_choices: FABER_VOICES,
    },
    exact_languages: PIPER_FABER_LANGUAGES,
    licence: LicenceDescriptor {
        id: Some("CC0-1.0"),
        category: LicenceCategory::Dataset,
        evidence_url: Some(
            "https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/faber/medium/MODEL_CARD",
        ),
        terms_fingerprint: None,
        requires_acceptance: false,
        validation: LicenceValidation::Partial,
    },
};

pub(super) static KOKORO_METADATA: ModelMetadata = ModelMetadata {
    presentation: ModelPresentationDescriptor {
        model_name: "Kokoro 82M",
        family_name: "Kokoro",
        quality: QualityTier::Unspecified,
        voice_choices: &[],
    },
    exact_languages: KOKORO_LANGUAGES,
    licence: UNKNOWN_LICENCE,
};

pub(super) static PIPER_EDRESSON_METADATA: ModelMetadata = ModelMetadata {
    presentation: ModelPresentationDescriptor {
        model_name: "Edresson",
        family_name: "Piper",
        quality: QualityTier::Low,
        voice_choices: EDRESSON_VOICES,
    },
    exact_languages: PIPER_EDRESSON_LANGUAGES,
    licence: UNKNOWN_LICENCE,
};

pub(super) static PIPER_LESSAC_METADATA: ModelMetadata = ModelMetadata {
    presentation: ModelPresentationDescriptor {
        model_name: "Lessac",
        family_name: "Piper",
        quality: QualityTier::Low,
        voice_choices: LESSAC_VOICES,
    },
    exact_languages: PIPER_LESSAC_LANGUAGES,
    licence: UNKNOWN_LICENCE,
};

pub(super) static PIPER_DEFAULT_METADATA: ModelMetadata = ModelMetadata {
    presentation: ModelPresentationDescriptor {
        model_name: "Piper default",
        family_name: "Piper",
        quality: QualityTier::Unspecified,
        voice_choices: &[],
    },
    exact_languages: &[],
    licence: UNKNOWN_LICENCE,
};

pub(super) static MELOTTS_METADATA: ModelMetadata = ModelMetadata {
    presentation: ModelPresentationDescriptor {
        model_name: "MeloTTS",
        family_name: "MeloTTS",
        quality: QualityTier::Unspecified,
        voice_choices: &[],
    },
    exact_languages: &[],
    licence: UNKNOWN_LICENCE,
};

pub(super) static QWEN3_METADATA: ModelMetadata = ModelMetadata {
    presentation: ModelPresentationDescriptor {
        model_name: "Qwen3-TTS 0.6B",
        family_name: "Qwen3-TTS",
        quality: QualityTier::Unspecified,
        voice_choices: &[],
    },
    exact_languages: &[],
    licence: UNKNOWN_LICENCE,
};
