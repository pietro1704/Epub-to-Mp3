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
    pub runtime_available: bool,
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
        name: "kokoro-int8-en-v0_19.tar.bz2",
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-en-v0_19.tar.bz2",
        sha256: "c9f0dd393615805b0bab050c340834d5e684e732aec91c0e860cd30e982c08bd",
        bytes: 103_248_205,
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
        download_bytes: 103_248_205,
        artifacts: KOKORO_ENGLISH_ARTIFACTS,
        runtime_available: false,
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
        runtime_available: true,
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
        runtime_available: false,
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
        runtime_available: false,
    },
];

pub fn candidates(
    language: &str,
    platform: ModelPlatform,
    android_api: Option<u32>,
) -> Vec<&'static TtsModelDescriptor> {
    let mut result: Vec<_> = MODELS
        .iter()
        .filter(|model| model.runtime_available)
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
    let _ = (language, platform, android_api);
    "none"
}

/// Selects the highest-ranked compatible engine from models installed locally.
///
/// An empty result is intentional: the application starts without voice models
/// and must not silently download or choose Piper as an implicit default.
pub fn installed_engine(
    language: &str,
    platform: ModelPlatform,
    android_api: Option<u32>,
    installed_model_ids: &[&str],
) -> Option<&'static str> {
    installed_ready_engine(language, platform, android_api, installed_model_ids, &[])
}

/// Selects a compatible installed engine only when the caller has verified
/// that its runtime can synthesize audio on this device.
pub fn installed_ready_engine(
    language: &str,
    platform: ModelPlatform,
    android_api: Option<u32>,
    installed_model_ids: &[&str],
    ready_model_ids: &[&str],
) -> Option<&'static str> {
    MODELS
        .iter()
        .filter(|model| model.supports(language, platform, android_api))
        .filter(|model| installed_model_ids.contains(&model.id))
        .filter(|model| ready_model_ids.contains(&model.id))
        .min_by_key(|model| model.default_rank)
        .map(|model| model.engine)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn does_not_select_unimplemented_kokoro_runtime() {
        assert_eq!(default_engine("en-US", ModelPlatform::Macos, None), "none");
    }

    #[test]
    fn does_not_claim_unverified_multilingual_kokoro_voices() {
        assert_eq!(default_engine("pt-BR", ModelPlatform::Macos, None), "none");
    }

    #[test]
    fn exposes_verified_kokoro_manifest() {
        let model = MODELS
            .iter()
            .find(|model| model.id == "kokoro-82m")
            .unwrap();
        assert_eq!(model.artifacts.len(), 1);
        assert_eq!(model.artifacts[0].bytes, 103_248_205);
        assert_eq!(model.artifacts[0].name, "kokoro-int8-en-v0_19.tar.bz2");
    }

    #[test]
    fn protects_android_api_28_from_native_models() {
        assert_eq!(
            default_engine("pt-BR", ModelPlatform::Android, Some(28)),
            "none"
        );
    }

    #[test]
    fn selects_only_an_installed_compatible_model() {
        assert_eq!(
            installed_engine("en-US", ModelPlatform::Macos, None, &[]),
            None
        );
        assert_eq!(
            installed_engine("en-US", ModelPlatform::Macos, None, &["kokoro-82m"]),
            None
        );
        assert_eq!(
            installed_ready_engine(
                "en-US",
                ModelPlatform::Macos,
                None,
                &["kokoro-82m"],
                &["kokoro-82m"]
            ),
            Some("kokoro")
        );
    }

    #[test]
    fn does_not_select_wrong_language() {
        assert!(candidates("ar", ModelPlatform::Linux, None).is_empty());
    }
}
