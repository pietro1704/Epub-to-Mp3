//! Additional immutable Piper voices. Audit: docs/research/2026-10-26-piper-voice-audit/.
use super::*;

const NATIVE_PLATFORMS: &[ModelPlatform] = &[
    ModelPlatform::Android,
    ModelPlatform::Ios,
    ModelPlatform::Macos,
    ModelPlatform::Linux,
    ModelPlatform::Windows,
];

pub(super) const CADU_MEDIUM: TtsModelDescriptor = TtsModelDescriptor {
    id: "pt_BR-cadu-medium",
    engine: "piper",
    languages: &["pt"],
    platforms: NATIVE_PLATFORMS,
    minimum_android_api: Some(28),
    default_rank: 1,
    download_bytes: 62_955_084,
    artifacts: &[
        TtsArtifactDescriptor {
            name: "model.onnx",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/cadu/medium/pt_BR-cadu-medium.onnx?download=true",
            sha256: "765f0809a6ea9035d4a6d0d008dbf8876e68b2dd32029312672fa8f405bdb535",
            bytes: 62_950_044,
        },
        TtsArtifactDescriptor {
            name: "model.onnx.json",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/cadu/medium/pt_BR-cadu-medium.onnx.json?download=true",
            sha256: "5fe03aa3d4901880554905b12075713cd552598c8a350455a1ec73f8b4e6be19",
            bytes: 5_040,
        },
    ],
    runtime_available: true,
    metadata: &ModelMetadata {
        presentation: ModelPresentationDescriptor {
            model_name: "Cadu",
            family_name: "Piper",
            quality: QualityTier::Medium,
            voice_choices: &[VoiceDescriptor { voice_id: None, name: "Cadu" }],
        },
        exact_languages: &[ExactLanguageDescriptor {
            tag: "pt-BR",
            frontend: Some("espeak-ng:pt-br"),
            validation: LanguageValidation::ArtifactDeclared,
        }],
        licence: LicenceDescriptor {
            id: Some("CC0-1.0"),
            category: LicenceCategory::Dataset,
            evidence_url: Some("https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/cadu/medium/MODEL_CARD"),
            terms_fingerprint: None,
            requires_acceptance: false,
            validation: LicenceValidation::Partial,
        },
    },
};

pub(super) const JEFF_MEDIUM: TtsModelDescriptor = TtsModelDescriptor {
    id: "pt_BR-jeff-medium",
    engine: "piper",
    languages: &["pt"],
    platforms: NATIVE_PLATFORMS,
    minimum_android_api: Some(28),
    default_rank: 2,
    download_bytes: 62_955_085,
    artifacts: &[
        TtsArtifactDescriptor {
            name: "model.onnx",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/jeff/medium/pt_BR-jeff-medium.onnx?download=true",
            sha256: "3a6f4c46355813c2b7bbc4d16b6d13d60ed72074b952a393baace82a7d0c94b5",
            bytes: 62_950_044,
        },
        TtsArtifactDescriptor {
            name: "model.onnx.json",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/jeff/medium/pt_BR-jeff-medium.onnx.json?download=true",
            sha256: "7bf8145b572b36806f5ce0f1d3322b6711975bc7d0473e8d36fced4a9ec0030d",
            bytes: 5_041,
        },
    ],
    runtime_available: true,
    metadata: &ModelMetadata {
        presentation: ModelPresentationDescriptor {
            model_name: "Jeff",
            family_name: "Piper",
            quality: QualityTier::Medium,
            voice_choices: &[VoiceDescriptor { voice_id: None, name: "Jeff" }],
        },
        exact_languages: &[ExactLanguageDescriptor {
            tag: "pt-BR",
            frontend: Some("espeak-ng:pt-br"),
            validation: LanguageValidation::ArtifactDeclared,
        }],
        licence: LicenceDescriptor {
            id: Some("CC0-1.0"),
            category: LicenceCategory::Dataset,
            evidence_url: Some("https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/jeff/medium/MODEL_CARD"),
            terms_fingerprint: None,
            requires_acceptance: false,
            validation: LicenceValidation::Partial,
        },
    },
};

pub(super) const DAVEFX_MEDIUM: TtsModelDescriptor = TtsModelDescriptor {
    id: "es_ES-davefx-medium",
    engine: "piper",
    languages: &["es"],
    platforms: NATIVE_PLATFORMS,
    minimum_android_api: Some(28),
    default_rank: 1,
    download_bytes: 63_206_111,
    artifacts: &[
        TtsArtifactDescriptor {
            name: "model.onnx",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx?download=true",
            sha256: "6658b03b1a6c316ee4c265a9896abc1393353c2d9e1bca7d66c2c442e222a917",
            bytes: 63_201_294,
        },
        TtsArtifactDescriptor {
            name: "model.onnx.json",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx.json?download=true",
            sha256: "0e0dda87c732f6f38771ff274a6380d9252f327dca77aa2963d5fbdf9ec54842",
            bytes: 4_817,
        },
    ],
    runtime_available: true,
    metadata: &ModelMetadata {
        presentation: ModelPresentationDescriptor {
            model_name: "Davefx",
            family_name: "Piper",
            quality: QualityTier::Medium,
            voice_choices: &[VoiceDescriptor { voice_id: None, name: "Davefx" }],
        },
        exact_languages: &[ExactLanguageDescriptor {
            tag: "es-ES",
            frontend: Some("espeak-ng:es"),
            validation: LanguageValidation::ArtifactDeclared,
        }],
        licence: LicenceDescriptor {
            id: Some("CC0-1.0"),
            category: LicenceCategory::Dataset,
            evidence_url: Some("https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/es/es_ES/davefx/medium/MODEL_CARD"),
            terms_fingerprint: None,
            requires_acceptance: false,
            validation: LicenceValidation::Partial,
        },
    },
};

pub(super) const LJSPEECH_MEDIUM: TtsModelDescriptor = TtsModelDescriptor {
    id: "en_US-ljspeech-medium",
    engine: "piper",
    languages: &["en"],
    platforms: NATIVE_PLATFORMS,
    minimum_android_api: Some(28),
    default_rank: 1,
    download_bytes: 63_536_351,
    artifacts: &[
        TtsArtifactDescriptor {
            name: "model.onnx",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx?download=true",
            sha256: "6f52a751e2349abe7a76735eb09dc1875298c77ea2342ffd2fef79ff81b87f22",
            bytes: 63_531_379,
        },
        TtsArtifactDescriptor {
            name: "model.onnx.json",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx.json?download=true",
            sha256: "141d612cc0a95ed7efc1ca936b845c2364967f2e9217c5dbfcf69fc4d6c65860",
            bytes: 4_972,
        },
    ],
    runtime_available: true,
    metadata: &ModelMetadata {
        presentation: ModelPresentationDescriptor {
            model_name: "LJ Speech",
            family_name: "Piper",
            quality: QualityTier::Medium,
            voice_choices: &[VoiceDescriptor { voice_id: None, name: "LJ Speech" }],
        },
        exact_languages: &[ExactLanguageDescriptor {
            tag: "en-US",
            frontend: Some("espeak-ng:en"),
            validation: LanguageValidation::ArtifactDeclared,
        }],
        licence: LicenceDescriptor {
            id: Some("LicenseRef-Public-Domain"),
            category: LicenceCategory::ModelWeights,
            evidence_url: Some("https://brycebeattie.com/files/tts/"),
            terms_fingerprint: None,
            requires_acceptance: false,
            validation: LicenceValidation::CreatorDeclared,
        },
    },
};

pub(super) const LJSPEECH_HIGH: TtsModelDescriptor = TtsModelDescriptor {
    id: "en_US-ljspeech-high",
    engine: "piper",
    languages: &["en"],
    platforms: NATIVE_PLATFORMS,
    minimum_android_api: Some(28),
    default_rank: 4,
    download_bytes: 114_203_981,
    artifacts: &[
        TtsArtifactDescriptor {
            name: "model.onnx",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/high/en_US-ljspeech-high.onnx?download=true",
            sha256: "5d4f08ba6a2a48c44592eed3ce56bf85e9de3dd4e20df90541ae68a8310c029a",
            bytes: 114_199_011,
        },
        TtsArtifactDescriptor {
            name: "model.onnx.json",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/high/en_US-ljspeech-high.onnx.json?download=true",
            sha256: "7e1f4634af596d83cca997fb7a931ba80b70f8a316a2655ee69c55365e0ace14",
            bytes: 4_970,
        },
    ],
    runtime_available: true,
    metadata: &ModelMetadata {
        presentation: ModelPresentationDescriptor {
            model_name: "LJ Speech",
            family_name: "Piper",
            quality: QualityTier::High,
            voice_choices: &[VoiceDescriptor { voice_id: None, name: "LJ Speech" }],
        },
        exact_languages: &[ExactLanguageDescriptor {
            tag: "en-US",
            frontend: Some("espeak-ng:en"),
            validation: LanguageValidation::ArtifactDeclared,
        }],
        licence: LicenceDescriptor {
            id: Some("LicenseRef-Public-Domain"),
            category: LicenceCategory::ModelWeights,
            evidence_url: Some("https://brycebeattie.com/files/tts/"),
            terms_fingerprint: None,
            requires_acceptance: false,
            validation: LicenceValidation::CreatorDeclared,
        },
    },
};

pub(super) const CORI_MEDIUM: TtsModelDescriptor = TtsModelDescriptor {
    id: "en_GB-cori-medium",
    engine: "piper",
    languages: &["en"],
    platforms: NATIVE_PLATFORMS,
    minimum_android_api: Some(28),
    default_rank: 2,
    download_bytes: 63_536_345,
    artifacts: &[
        TtsArtifactDescriptor {
            name: "model.onnx",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_GB/cori/medium/en_GB-cori-medium.onnx?download=true",
            sha256: "1899f98e5fb8310154f3c2973f4b8a929ba7245e722b3d3a85680b833d95f10d",
            bytes: 63_531_379,
        },
        TtsArtifactDescriptor {
            name: "model.onnx.json",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_GB/cori/medium/en_GB-cori-medium.onnx.json?download=true",
            sha256: "e262c16d7f192f69d4edd6b4ef8a5915379e67495fcc402f1ab15eeb33da3d36",
            bytes: 4_966,
        },
    ],
    runtime_available: true,
    metadata: &ModelMetadata {
        presentation: ModelPresentationDescriptor {
            model_name: "Cori",
            family_name: "Piper",
            quality: QualityTier::Medium,
            voice_choices: &[VoiceDescriptor { voice_id: None, name: "Cori" }],
        },
        exact_languages: &[ExactLanguageDescriptor {
            tag: "en-GB",
            frontend: Some("espeak-ng:en"),
            validation: LanguageValidation::ArtifactDeclared,
        }],
        licence: LicenceDescriptor {
            id: Some("LicenseRef-Public-Domain"),
            category: LicenceCategory::ModelWeights,
            evidence_url: Some("https://brycebeattie.com/files/tts/"),
            terms_fingerprint: None,
            requires_acceptance: false,
            validation: LicenceValidation::CreatorDeclared,
        },
    },
};

pub(super) const KRISTIN_MEDIUM: TtsModelDescriptor = TtsModelDescriptor {
    id: "en_US-kristin-medium",
    engine: "piper",
    languages: &["en"],
    platforms: NATIVE_PLATFORMS,
    minimum_android_api: Some(28),
    default_rank: 3,
    download_bytes: 63_536_347,
    artifacts: &[
        TtsArtifactDescriptor {
            name: "model.onnx",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/kristin/medium/en_US-kristin-medium.onnx?download=true",
            sha256: "5849957f929cbf720c258f8458692d6103fff2f0e3d3b19c8259474bb06a18d4",
            bytes: 63_531_379,
        },
        TtsArtifactDescriptor {
            name: "model.onnx.json",
            url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/kristin/medium/en_US-kristin-medium.onnx.json?download=true",
            sha256: "5681426d4aead22195de70531eeeeddb46493cfaffc5764b2ea3db73428b651c",
            bytes: 4_968,
        },
    ],
    runtime_available: true,
    metadata: &ModelMetadata {
        presentation: ModelPresentationDescriptor {
            model_name: "Kristin",
            family_name: "Piper",
            quality: QualityTier::Medium,
            voice_choices: &[VoiceDescriptor { voice_id: None, name: "Kristin" }],
        },
        exact_languages: &[ExactLanguageDescriptor {
            tag: "en-US",
            frontend: Some("espeak-ng:en"),
            validation: LanguageValidation::ArtifactDeclared,
        }],
        licence: LicenceDescriptor {
            id: Some("LicenseRef-Public-Domain"),
            category: LicenceCategory::ModelWeights,
            evidence_url: Some("https://brycebeattie.com/files/tts/"),
            terms_fingerprint: None,
            requires_acceptance: false,
            validation: LicenceValidation::CreatorDeclared,
        },
    },
};
