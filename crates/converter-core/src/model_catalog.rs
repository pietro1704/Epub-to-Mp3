//! Shared model catalog and deterministic local-engine selection.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelPlatform {
    Android,
    Ios,
    Macos,
    Linux,
    Windows,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TtsArtifactDescriptor {
    pub name: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
    pub bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TtsModelDescriptor {
    pub id: &'static str,
    pub engine: &'static str,
    pub languages: &'static [&'static str],
    pub platforms: &'static [ModelPlatform],
    pub minimum_android_api: Option<u32>,
    pub default_rank: u8,
    pub download_bytes: u64,
    pub artifacts: &'static [TtsArtifactDescriptor],
}

impl TtsModelDescriptor {
    pub fn supports(
        &self,
        language: &str,
        platform: ModelPlatform,
        android_api: Option<u32>,
    ) -> bool {
        let language = language
            .split('-')
            .next()
            .unwrap_or(language)
            .to_ascii_lowercase();
        self.languages.iter().any(|value| *value == language)
            && self.platforms.contains(&platform)
            && (platform != ModelPlatform::Android
                || self.minimum_android_api.is_none()
                || android_api.unwrap_or(0) >= self.minimum_android_api.unwrap())
    }
}

static KOKORO_ENGLISH_ARTIFACTS: &[TtsArtifactDescriptor] = &[
    TtsArtifactDescriptor {
        name: "onnx/model_quantized.onnx",
        url: "https://huggingface.co/onnx-community/Kokoro-82M-ONNX/resolve/main/onnx/model_quantized.onnx",
        sha256: "0d55b15d4b735d61a21b0105136bc81b8768c4db94753193c19354fa863cd556",
        bytes: 92_360_543,
    },
    TtsArtifactDescriptor {
        name: "config.json",
        url: "https://huggingface.co/onnx-community/Kokoro-82M-ONNX/resolve/main/config.json",
        sha256: "df34b4f930b23447cd4dc410fabfb42eb3f24e803e6c3f97d618fb359380a36f",
        bytes: 44,
    },
    TtsArtifactDescriptor {
        name: "tokenizer.json",
        url: "https://huggingface.co/onnx-community/Kokoro-82M-ONNX/resolve/main/tokenizer.json",
        sha256: "ee301fc39cf903ddbb463564630a28767785e3a11edd6d8226e92d4b4ef131bb",
        bytes: 4_608,
    },
    TtsArtifactDescriptor {
        name: "tokenizer_config.json",
        url: "https://huggingface.co/onnx-community/Kokoro-82M-ONNX/resolve/main/tokenizer_config.json",
        sha256: "be1cb066d6ef6b074b3f15e6a6dd21ac88ff3cdaedf325f0aaed686c70f75d20",
        bytes: 113,
    },
    TtsArtifactDescriptor {
        name: "voices/af.bin",
        url: "https://huggingface.co/onnx-community/Kokoro-82M-ONNX/resolve/main/voices/af.bin",
        sha256: "a4f11d9d055a12bfa0db2668a3e4f0ef8fd1f1ccca69494479718e44dbf9e41a",
        bytes: 524_288,
    },
];

pub static MODELS: &[TtsModelDescriptor] = &[
    TtsModelDescriptor {
        id: "kokoro-82m",
        engine: "kokoro",
        languages: &["en"],
        platforms: &[
            ModelPlatform::Android,
            ModelPlatform::Ios,
            ModelPlatform::Macos,
            ModelPlatform::Linux,
            ModelPlatform::Windows,
        ],
        minimum_android_api: Some(29),
        default_rank: 1,
        download_bytes: 92_889_596,
        artifacts: KOKORO_ENGLISH_ARTIFACTS,
    },
    TtsModelDescriptor {
        id: "piper-default",
        engine: "piper",
        languages: &["de", "en", "es", "fr", "it", "pt"],
        platforms: &[
            ModelPlatform::Android,
            ModelPlatform::Ios,
            ModelPlatform::Macos,
            ModelPlatform::Linux,
            ModelPlatform::Windows,
        ],
        minimum_android_api: Some(29),
        default_rank: 2,
        download_bytes: 25 * 1024 * 1024,
        artifacts: &[],
    },
    TtsModelDescriptor {
        id: "melotts",
        engine: "melotts",
        languages: &["en", "es", "fr", "zh", "ja", "ko"],
        platforms: &[
            ModelPlatform::Macos,
            ModelPlatform::Linux,
            ModelPlatform::Windows,
        ],
        minimum_android_api: None,
        default_rank: 3,
        download_bytes: 150 * 1024 * 1024,
        artifacts: &[],
    },
    TtsModelDescriptor {
        id: "qwen3-tts-0.6b",
        engine: "qwen3",
        languages: &["de", "en", "es", "fr", "it", "ja", "ko", "pt", "ru", "zh"],
        platforms: &[
            ModelPlatform::Macos,
            ModelPlatform::Linux,
            ModelPlatform::Windows,
        ],
        minimum_android_api: None,
        default_rank: 4,
        download_bytes: 700 * 1024 * 1024,
        artifacts: &[],
    },
];

pub fn candidates(
    language: &str,
    platform: ModelPlatform,
    android_api: Option<u32>,
) -> Vec<&'static TtsModelDescriptor> {
    let mut result: Vec<_> = MODELS
        .iter()
        .filter(|model| model.supports(language, platform, android_api))
        .collect();
    result.sort_by_key(|model| model.default_rank);
    result
}

pub fn default_engine(
    language: &str,
    platform: ModelPlatform,
    android_api: Option<u32>,
) -> &'static str {
    candidates(language, platform, android_api)
        .first()
        .map(|model| model.engine)
        .unwrap_or("piper")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefers_kokoro_for_supported_english_on_desktop() {
        assert_eq!(
            default_engine("en-US", ModelPlatform::Macos, None),
            "kokoro"
        );
    }

    #[test]
    fn does_not_claim_unverified_multilingual_kokoro_voices() {
        assert_eq!(default_engine("pt-BR", ModelPlatform::Macos, None), "piper");
    }

    #[test]
    fn exposes_verified_kokoro_manifest() {
        let model = MODELS
            .iter()
            .find(|model| model.id == "kokoro-82m")
            .unwrap();
        assert_eq!(model.artifacts.len(), 5);
        assert_eq!(model.artifacts[0].bytes, 92_360_543);
        assert_eq!(model.artifacts[4].name, "voices/af.bin");
    }

    #[test]
    fn protects_android_api_28_from_native_models() {
        assert_eq!(
            default_engine("pt-BR", ModelPlatform::Android, Some(28)),
            "piper"
        );
    }

    #[test]
    fn does_not_select_wrong_language() {
        assert!(candidates("ar", ModelPlatform::Linux, None).is_empty());
    }
}
