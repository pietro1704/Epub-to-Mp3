//! Versioned projection of model identity, evidence and availability policy.

mod contract;
pub use contract::*;
#[cfg(not(target_arch = "wasm32"))]
mod inspection;

use crate::model_catalog::{model_revision, MODELS};
use crate::tts_preferences::TtsSelection;
use crate::tts_session::{SessionSelection, CONTRACT_VERSION};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CatalogError {
    #[error("invalid speech model catalogue: {0}")]
    Invalid(String),
}

#[derive(Debug, Default)]
pub struct SpeechModelLibrary;

impl SpeechModelLibrary {
    pub fn snapshot(&self, query: CatalogQuery) -> Result<SpeechModelSnapshot, CatalogError> {
        validate_catalog(MODELS)?;
        let catalog_revision = catalog_revision_for(MODELS)?;
        let default_selection = resolved_default_selection()?;
        let language = query
            .language
            .split(['-', '_'])
            .next()
            .unwrap_or(&query.language)
            .to_ascii_lowercase();
        let target = CatalogTarget {
            language: query.language.clone(),
            platform: platform_name(query.platform),
            android_api: query.android_api,
            architecture: query.architecture.clone(),
            os_version: query.os_version.clone(),
        };
        let entries = MODELS
            .iter()
            .map(|model| {
                let installable = !model.artifacts.is_empty();
                let mut compatibility_reasons = Vec::new();
                if !model.languages.iter().any(|tag| *tag == language) {
                    compatibility_reasons.push(CompatibilityReason::UnsupportedLanguage);
                }
                if !model.platforms.contains(&query.platform) {
                    compatibility_reasons.push(CompatibilityReason::UnsupportedPlatform);
                }
                if query.platform == crate::model_catalog::ModelPlatform::Android
                    && model
                        .minimum_android_api
                        .is_some_and(|minimum| query.android_api.unwrap_or(0) < minimum)
                {
                    compatibility_reasons.push(CompatibilityReason::AndroidApiTooLow);
                }
                if model.engine == "piper"
                    && crate::model_catalog::validate_piper_quality(model.id).is_err()
                {
                    compatibility_reasons.push(CompatibilityReason::QualityDisabled);
                }
                let compatible = compatibility_reasons.is_empty();
                let mut selection_reasons = Vec::new();
                if !compatible {
                    selection_reasons.push(SelectionReason::Incompatible);
                }
                if !installable {
                    selection_reasons.push(SelectionReason::NotInstallable);
                } else {
                    selection_reasons.extend([
                        SelectionReason::InstallationNotInspected,
                        SelectionReason::ReadinessNotInspected,
                    ]);
                }
                SpeechModelEntry {
                    identity: ModelIdentity {
                        provider: model.engine.into(),
                        runtime: crate::tts_session::runtime_for(model.engine).map(str::to_owned),
                        model_id: model.id.into(),
                        model_revision: model_revision(model),
                    },
                    presentation: model.metadata.presentation,
                    language_evidence: LanguageEvidence {
                        routing_tags: model.languages.iter().map(|tag| (*tag).into()).collect(),
                        exact_tags: model.metadata.exact_languages.to_vec(),
                    },
                    distribution: Distribution {
                        installable,
                        artifacts: model.artifacts.to_vec(),
                        download_bytes: installable.then_some(model.download_bytes),
                        installed_bytes: model.installed_artifact_bytes(),
                    },
                    licence: model.metadata.licence,
                    compatibility: Compatibility {
                        compatible,
                        reasons: compatibility_reasons,
                    },
                    installation: InstallationStatus {
                        state: InstallationState::NotInspected,
                        verified_revision: None,
                        installed_bytes: None,
                    },
                    readiness: ReadinessStatus {
                        state: ReadinessState::NotInspected,
                        active_runtime_revision: None,
                        failure: None,
                    },
                    selection: SelectionAvailability {
                        selectable: false,
                        reasons: selection_reasons,
                    },
                }
            })
            .collect();
        Ok(SpeechModelSnapshot {
            schema_version: SCHEMA_VERSION,
            synthesis_contract_version: CONTRACT_VERSION,
            generated_from_catalog_revision: catalog_revision,
            target,
            default_selection,
            providers: crate::tts_session::builtin_descriptors(),
            entries,
        })
    }
}

fn validate_catalog(
    models: &[crate::model_catalog::TtsModelDescriptor],
) -> Result<(), CatalogError> {
    use std::collections::HashSet;
    use std::path::{Component, Path};

    let mut model_ids = HashSet::new();
    for model in models {
        if model.id.is_empty() || !model_ids.insert(model.id) {
            return Err(CatalogError::Invalid(format!(
                "model id is empty or duplicated: {}",
                model.id
            )));
        }
        let mut artifact_names = HashSet::new();
        let mut artifact_bytes = 0u64;
        for artifact in model.artifacts {
            let path = Path::new(artifact.name);
            if artifact.name.is_empty()
                || path.is_absolute()
                || path.components().any(|component| {
                    matches!(component, Component::ParentDir | Component::Prefix(_))
                })
                || !artifact_names.insert(artifact.name)
            {
                return Err(CatalogError::Invalid(format!(
                    "invalid or duplicated artifact name for {}: {}",
                    model.id, artifact.name
                )));
            }
            if !artifact.url.starts_with("https://")
                || artifact.url.contains("/resolve/main/")
                || artifact.url.contains("/resolve/master/")
                || artifact.url.contains("/releases/latest/")
            {
                return Err(CatalogError::Invalid(format!(
                    "artifact URL is not immutable HTTPS for {}: {}",
                    model.id, artifact.url
                )));
            }
            if artifact.sha256.len() != 64
                || !artifact.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
            {
                return Err(CatalogError::Invalid(format!(
                    "artifact SHA-256 is invalid for {}: {}",
                    model.id, artifact.name
                )));
            }
            if artifact.bytes == 0 {
                return Err(CatalogError::Invalid(format!(
                    "artifact byte count is zero for {}: {}",
                    model.id, artifact.name
                )));
            }
            artifact_bytes = artifact_bytes.checked_add(artifact.bytes).ok_or_else(|| {
                CatalogError::Invalid(format!("artifact byte count overflow for {}", model.id))
            })?;
        }
        if !model.artifacts.is_empty() && model.download_bytes != artifact_bytes {
            return Err(CatalogError::Invalid(format!(
                "download byte count does not match artifacts for {}",
                model.id
            )));
        }

        let presentation = &model.metadata.presentation;
        if presentation.model_name.trim().is_empty() || presentation.family_name.trim().is_empty() {
            return Err(CatalogError::Invalid(format!(
                "presentation labels are empty for {}",
                model.id
            )));
        }
        let mut voice_ids = HashSet::new();
        for voice in presentation.voice_choices {
            if voice.name.trim().is_empty()
                || voice
                    .voice_id
                    .is_some_and(|voice_id| voice_id.trim().is_empty())
                || !voice_ids.insert(voice.voice_id)
            {
                return Err(CatalogError::Invalid(format!(
                    "voice identity or label is invalid for {}",
                    model.id
                )));
            }
        }

        let mut exact_languages = HashSet::new();
        for evidence in model.metadata.exact_languages {
            let normalized = evidence.tag.to_ascii_lowercase();
            let routing_tag = normalized.split(['-', '_']).next().unwrap_or(&normalized);
            if normalized.is_empty()
                || !evidence
                    .tag
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                || !model.languages.contains(&routing_tag)
                || evidence
                    .frontend
                    .is_some_and(|frontend| frontend.trim().is_empty())
                || !exact_languages.insert(normalized)
            {
                return Err(CatalogError::Invalid(format!(
                    "exact language evidence is invalid for {}",
                    model.id
                )));
            }
        }

        let licence = &model.metadata.licence;
        if licence.id.is_some_and(|id| id.trim().is_empty())
            || licence
                .evidence_url
                .is_some_and(|url| !url.starts_with("https://"))
            || licence.terms_fingerprint.is_some_and(|fingerprint| {
                fingerprint.len() != 64 || !fingerprint.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
            || licence.id.is_some_and(|_| licence.evidence_url.is_none())
            || (licence.requires_acceptance
                && (licence.id.is_none()
                    || licence.evidence_url.is_none()
                    || licence.terms_fingerprint.is_none()))
        {
            return Err(CatalogError::Invalid(format!(
                "licence evidence is invalid for {}",
                model.id
            )));
        }
    }
    Ok(())
}

fn resolved_default_selection() -> Result<SessionSelection, CatalogError> {
    let mut selection = SessionSelection::from_legacy(&TtsSelection::default())
        .map_err(|error| CatalogError::Invalid(error.to_string()))?;
    if let Some(model_id) = selection.model_id.as_deref() {
        let model = MODELS
            .iter()
            .find(|model| model.id == model_id && model.engine == selection.provider)
            .ok_or_else(|| {
                CatalogError::Invalid("default selection is absent from catalog".into())
            })?;
        selection.model_revision = model_revision(model);
    }
    Ok(selection)
}

fn catalog_revision_for(
    models: &[crate::model_catalog::TtsModelDescriptor],
) -> Result<String, CatalogError> {
    let material = models
        .iter()
        .map(|model| {
            serde_json::json!({
                "descriptor": model,
                "metadata": model.metadata,
                "revision": model_revision(model),
            })
        })
        .collect::<Vec<_>>();
    let bytes =
        serde_json::to_vec(&material).map_err(|error| CatalogError::Invalid(error.to_string()))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

#[cfg(test)]
mod tests;

#[cfg(test)]
fn tests_query() -> CatalogQuery {
    CatalogQuery {
        language: "pt-BR".into(),
        platform: crate::model_catalog::ModelPlatform::Macos,
        android_api: None,
        architecture: "arm64".into(),
        os_version: Some("15.5".into()),
    }
}
