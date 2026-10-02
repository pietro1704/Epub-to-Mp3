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
pub struct TtsModelDescriptor {
    pub id: &'static str,
    pub engine: &'static str,
    pub languages: &'static [&'static str],
    pub platforms: &'static [ModelPlatform],
    pub minimum_android_api: Option<u32>,
    pub default_rank: u8,
    pub download_bytes: u64,
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

pub static MODELS: &[TtsModelDescriptor] = &[
    TtsModelDescriptor {
        id: "kokoro-82m",
        engine: "kokoro",
        languages: &["en", "es", "fr", "it", "pt", "ja", "zh"],
        platforms: &[
            ModelPlatform::Android,
            ModelPlatform::Ios,
            ModelPlatform::Macos,
            ModelPlatform::Linux,
            ModelPlatform::Windows,
        ],
        minimum_android_api: Some(29),
        default_rank: 1,
        download_bytes: 82 * 1024 * 1024,
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
    fn prefers_kokoro_on_desktop() {
        assert_eq!(
            default_engine("pt-BR", ModelPlatform::Macos, None),
            "kokoro"
        );
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
