//! Shared model catalog and deterministic local-engine selection.

use serde::{Deserialize, Serialize};

mod metadata;
mod piper_language_models;
mod piper_voices;
pub use metadata::{
    ExactLanguageDescriptor, LanguageValidation, LicenceCategory, LicenceDescriptor,
    LicenceValidation, ModelMetadata, ModelPresentationDescriptor, QualityTier, VoiceDescriptor,
};

/// Product policy shared by native runtimes and browser/WASM selection.
pub(crate) fn validate_piper_quality(identifier: &str) -> Result<(), String> {
    let identifier = identifier.trim().to_ascii_lowercase();
    let stem = identifier.split('.').next().unwrap_or(&identifier);
    if stem == "low" || stem.ends_with("-low") || stem.ends_with("_low") {
        return Err("Piper low quality models require an explicit catalog selection and cannot be fallbacks".into());
    }
    Ok(())
}

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
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
    #[serde(skip)]
    pub metadata: &'static ModelMetadata,
}

impl TtsModelDescriptor {
    /// Uncompressed Piper payload size; archive extraction footprints stay unknown.
    pub fn installed_artifact_bytes(&self) -> Option<u64> {
        if self.engine != "piper"
            || self.artifacts.is_empty()
            || self
                .artifacts
                .iter()
                .any(|artifact| !matches!(artifact.name, "model.onnx" | "model.onnx.json"))
        {
            return None;
        }
        self.artifacts
            .iter()
            .try_fold(0u64, |bytes, artifact| bytes.checked_add(artifact.bytes))
    }

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

pub fn model_revision(model: &TtsModelDescriptor) -> Option<String> {
    revision_from_hashes(model.artifacts.iter().map(|artifact| artifact.sha256))
}

pub fn revision_from_hashes<'a>(hashes: impl IntoIterator<Item = &'a str>) -> Option<String> {
    let hashes = hashes.into_iter().collect::<Vec<_>>();
    (!hashes.is_empty()).then(|| hashes.join(":"))
}

static PIPER_PT_BR_EDRESSON_LOW_ARTIFACTS: &[TtsArtifactDescriptor] = &[
    TtsArtifactDescriptor {
        name: "model.onnx",
        url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/edresson/low/pt_BR-edresson-low.onnx?download=true",
        sha256: "de4cecee38b30bb1a6378a337af605d59f0c377df702c6a6752870db8991cd84",
        bytes: 63_104_526,
    },
    TtsArtifactDescriptor {
        name: "model.onnx.json",
        url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/edresson/low/pt_BR-edresson-low.onnx.json?download=true",
        sha256: "f138992d2e777d1e3aa0bbb14c2d324307b0f342c1bcf20978765b3bea506c56",
        bytes: 4_168,
    },
];

static PIPER_EN_US_LESSAC_LOW_ARTIFACTS: &[TtsArtifactDescriptor] = &[
    TtsArtifactDescriptor {
        name: "model.onnx",
        url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/lessac/low/en_US-lessac-low.onnx?download=true",
        sha256: "f7d01dde371555732c4c314111ac79672b1a5ce2fc19266ab42178fd8df7f375",
        bytes: 63_201_294,
    },
    TtsArtifactDescriptor {
        name: "model.onnx.json",
        url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/lessac/low/en_US-lessac-low.onnx.json?download=true",
        sha256: "45754dfdebb3b8661c3fc564713772deec6e064feeb5b4e9594857dc7305193a",
        bytes: 4_882,
    },
];

const EXPLICIT_PIPER_MODELS: &[TtsModelDescriptor] = &[
    TtsModelDescriptor {
        id: "pt_BR-edresson-low",
        engine: "piper",
        languages: &["pt"],
        platforms: &[
            ModelPlatform::Android,
            ModelPlatform::Ios,
            ModelPlatform::Macos,
            ModelPlatform::Linux,
            ModelPlatform::Windows,
        ],
        minimum_android_api: Some(28),
        default_rank: 1,
        download_bytes: 63_108_694,
        artifacts: PIPER_PT_BR_EDRESSON_LOW_ARTIFACTS,
        runtime_available: true,
        metadata: &metadata::PIPER_EDRESSON_METADATA,
    },
    TtsModelDescriptor {
        id: "en_US-lessac-low",
        engine: "piper",
        languages: &["en"],
        platforms: &[
            ModelPlatform::Android,
            ModelPlatform::Ios,
            ModelPlatform::Macos,
            ModelPlatform::Linux,
            ModelPlatform::Windows,
        ],
        minimum_android_api: Some(28),
        default_rank: 1,
        download_bytes: 63_206_176,
        artifacts: PIPER_EN_US_LESSAC_LOW_ARTIFACTS,
        runtime_available: true,
        metadata: &metadata::PIPER_LESSAC_METADATA,
    },
];

static PIPER_FABER_ARTIFACTS: &[TtsArtifactDescriptor] = &[
    TtsArtifactDescriptor { name: "model.onnx", url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx?download=true", sha256: "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7", bytes: 63_201_294 },
    TtsArtifactDescriptor { name: "model.onnx.json", url: "https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx.json?download=true", sha256: "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f", bytes: 4_855 },
];

const BASE_MODELS: &[TtsModelDescriptor] = &[
    TtsModelDescriptor {
        id: "pt_BR-faber-medium",
        engine: "piper",
        languages: &["pt"],
        platforms: &[
            ModelPlatform::Android,
            ModelPlatform::Ios,
            ModelPlatform::Macos,
            ModelPlatform::Linux,
            ModelPlatform::Windows,
        ],
        minimum_android_api: Some(28),
        default_rank: 0,
        download_bytes: 63_206_149,
        artifacts: PIPER_FABER_ARTIFACTS,
        runtime_available: true,
        metadata: &metadata::PIPER_FABER_METADATA,
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
        metadata: &metadata::PIPER_DEFAULT_METADATA,
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
        metadata: &metadata::MELOTTS_METADATA,
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
        metadata: &metadata::QWEN3_METADATA,
    },
    piper_voices::CADU_MEDIUM,
    piper_voices::JEFF_MEDIUM,
    piper_voices::DAVEFX_MEDIUM,
    piper_voices::LJSPEECH_MEDIUM,
    piper_voices::LJSPEECH_HIGH,
    piper_voices::CORI_MEDIUM,
    piper_voices::KRISTIN_MEDIUM,
];

pub static MODELS: &[TtsModelDescriptor] = &{
    let additional = piper_language_models::MODELS;
    let mut result = [BASE_MODELS[0]; BASE_MODELS.len() + piper_language_models::MODELS.len()];
    let mut index = 0;
    while index < BASE_MODELS.len() {
        result[index] = BASE_MODELS[index];
        index += 1;
    }
    let mut extra = 0;
    while extra < additional.len() {
        result[index + extra] = additional[extra];
        extra += 1;
    }
    result
};

/// Looks up an exact model ID for direct installation or a captured selection.
/// Enumeration and recommendations use `MODELS` instead.
pub fn model_by_id(id: &str) -> Option<&'static TtsModelDescriptor> {
    manual_models().find(|model| model.id == id)
}

/// Enumerates installed/downloadable choices for an explicit model browser.
pub fn manual_models() -> impl Iterator<Item = &'static TtsModelDescriptor> {
    MODELS.iter().chain(EXPLICIT_PIPER_MODELS)
}

pub fn candidates(
    language: &str,
    platform: ModelPlatform,
    android_api: Option<u32>,
) -> Vec<&'static TtsModelDescriptor> {
    let mut result: Vec<_> = MODELS
        .iter()
        .filter(|model| {
            model.runtime_available
                && (model.engine != "piper" || validate_piper_quality(model.id).is_ok())
        })
        .filter(|model| model.supports(language, platform, android_api))
        .collect();
    result.sort_by_key(|model| model.default_rank);
    result
}

/// Catalog voices for automatic narration in preference order. A bare `pt`
/// keeps the app's Brazilian Portuguese default.
pub(crate) fn automatic_piper_models(language: &str) -> Vec<&'static TtsModelDescriptor> {
    let tag = language.replace('_', "-");
    if tag.eq_ignore_ascii_case("pt") || tag.eq_ignore_ascii_case("pt-BR") {
        return MODELS
            .iter()
            .filter(|model| model.id == crate::tts_preferences::FABER_MODEL_ID)
            .collect();
    }
    let base = tag.split('-').next().unwrap_or(&tag);
    let mut voices: Vec<_> = MODELS
        .iter()
        .filter(|model| {
            model.engine == "piper"
                && model.runtime_available
                && !model.artifacts.is_empty()
                && matches!(
                    model.metadata.presentation.quality,
                    QualityTier::High | QualityTier::Medium
                )
                && model
                    .languages
                    .iter()
                    .any(|value| value.eq_ignore_ascii_case(base))
        })
        .collect();
    voices.sort_by_key(|model| {
        let exact = model
            .metadata
            .exact_languages
            .iter()
            .any(|value| value.tag.eq_ignore_ascii_case(&tag));
        (
            model.metadata.presentation.quality != QualityTier::High,
            !exact,
            model.default_rank,
        )
    });
    voices
}

/// A base language with at least one catalog model for a platform.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CatalogLanguage {
    pub tag: String,
    pub model_count: usize,
    /// 1-based position in [`LANGUAGE_POPULARITY`]; absent for languages outside the list.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub popularity_rank: Option<u32>,
}

/// Base languages from the most to the least popular for reading and listening to books. The one
/// list every client uses to order the languages of the Models screen (after the languages of the
/// system); languages outside it follow in alphabetical order. Edit it here only.
pub const LANGUAGE_POPULARITY: [&str; 30] = [
    "en", "es", "pt", "fr", "de", "it", "ru", "zh", "ja", "ko", "ar", "hi", "tr", "nl", "pl", "uk",
    "sv", "id", "vi", "cs", "ro", "el", "hu", "fi", "da", "nb", "th", "he", "bg", "ca",
];

fn popularity_rank(tag: &str) -> Option<u32> {
    LANGUAGE_POPULARITY
        .iter()
        .position(|candidate| candidate.eq_ignore_ascii_case(tag))
        .map(|position| position as u32 + 1)
}

/// Distinct base languages that have at least one usable catalog model on the
/// platform (any provider), sorted by tag. Display names are the client's.
pub fn catalog_languages(
    platform: ModelPlatform,
    android_api: Option<u32>,
) -> Vec<CatalogLanguage> {
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for model in MODELS.iter().filter(|model| {
        model.runtime_available
            && (model.engine != "piper" || validate_piper_quality(model.id).is_ok())
    }) {
        for language in model.languages {
            if model.supports(language, platform, android_api) {
                *counts.entry((*language).to_owned()).or_default() += 1;
            }
        }
    }
    counts
        .into_iter()
        .map(|(tag, model_count)| CatalogLanguage {
            popularity_rank: popularity_rank(&tag),
            tag,
            model_count,
        })
        .collect()
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
        .filter(|model| model.engine != "piper" || validate_piper_quality(model.id).is_ok())
        .filter(|model| ready_model_ids.contains(&model.id))
        .min_by_key(|model| model.default_rank)
        .map(|model| model.engine)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn does_not_select_an_unavailable_english_runtime() {
        assert_eq!(default_engine("en-US", ModelPlatform::Macos, None), "none");
    }

    #[test]
    fn does_not_select_a_model_that_has_not_been_installed() {
        assert_eq!(default_engine("pt-BR", ModelPlatform::Macos, None), "none");
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
            None
        );
    }

    #[test]
    fn does_not_select_wrong_language() {
        assert!(candidates("zz", ModelPlatform::Linux, None).is_empty());
    }
}
