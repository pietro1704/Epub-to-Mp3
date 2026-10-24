//! Content, runtime and voice cache identity behind the synthesis seam.
use super::{ConversionRequest, ConversionWorker, WorkerError};
use crate::{cache, tts_preferences::TtsPreferences};
impl ConversionWorker {
    pub(super) fn typed_cache_request_key(
        &self,
        request: &ConversionRequest,
        preferences: &TtsPreferences,
        language: Option<&str>,
        base_request_key: &str,
    ) -> Result<String, WorkerError> {
        preferences.validate(language).map_err(WorkerError::Piper)?;
        let mut identities = Vec::new();
        for selection in std::iter::once(&preferences.primary).chain(preferences.secondary.iter()) {
            let session = crate::tts_session::SessionSelection::from_legacy(selection)
                .map_err(|error| WorkerError::Unsupported(error.to_string()))?;
            let descriptor = self
                .tts_registry
                .descriptors()
                .into_iter()
                .chain(crate::tts_session::builtin_descriptors())
                .find(|descriptor| {
                    descriptor.provider == session.provider && descriptor.runtime == session.runtime
                })
                .ok_or_else(|| {
                    WorkerError::Unsupported("Requested synthesis runtime is unavailable".into())
                })?;
            identities.push(
                serde_json::to_string(&(
                    crate::tts_session::CONTRACT_VERSION,
                    "text-v1",
                    &session,
                    &descriptor,
                    crate::tts_session::AudioFormat::Mp3,
                ))
                .map_err(cache::CacheError::from)?,
            );
            if self.tts_registry.descriptors().iter().any(|registered| {
                registered.provider == session.provider && registered.runtime == session.runtime
            }) {
                let mut sessions = self.tts_sessions.lock().expect("TTS session lock");
                let key = (
                    request.job_id.clone(),
                    language.unwrap_or("pt-BR").to_owned(),
                    serde_json::to_string(selection).expect("selection serialization"),
                );
                if !sessions.contains_key(&key) {
                    match self
                        .tts_registry
                        .prepare(&session, language.unwrap_or("pt-BR"))
                    {
                        Ok(prepared) => {
                            sessions.insert(key.clone(), prepared);
                        }
                        Err(error) if preferences.continues_native() => {
                            identities.push(format!("unavailable:{error}"));
                            continue;
                        }
                        Err(error) => return Err(WorkerError::Unsupported(error.to_string())),
                    }
                }
                identities.push(
                    crate::tts_session::cache_material(
                        &base_request_key,
                        "text-v1",
                        sessions.get(&key).expect("prepared identity").identity(),
                        &crate::tts_session::AudioFormat::Mp3,
                    )
                    .unwrap_or_else(|_| {
                        format!("opaque:{}:{:032x}", request.job_id, rand::random::<u128>())
                    }),
                );
                continue;
            }
            if selection.engine == "kokoro" {
                let root = request
                    .models_root
                    .as_ref()
                    .unwrap_or(&self.config.paths.piper_models_dir)
                    .join(selection.model_id.as_deref().unwrap_or("kokoro-82m"));
                let installed = super::kokoro_model_identity::validate_provenance(
                    &root,
                    selection.model_id.as_deref().unwrap_or("kokoro-82m"),
                )
                .and_then(|_| {
                    super::kokoro_model_identity::extracted_identity(
                        &root,
                        cfg!(feature = "kokoro-sherpa-runtime"),
                    )
                });
                match installed {
                    Ok(artifacts) => identities
                        .push(serde_json::to_string(&artifacts).map_err(cache::CacheError::from)?),
                    Err(error)
                        if preferences.continues_native() || selection != &preferences.primary =>
                    {
                        identities.push(format!("unavailable:{error}"));
                    }
                    Err(error) => return Err(error),
                }
                identities.push(format!(
                    "unverified-extraction:{}:{:032x}",
                    request.job_id,
                    rand::random::<u128>()
                ));
            } else if selection.engine != "piper" {
                if let Some(id) = &selection.model_id {
                    let manifest = crate::model_store::ModelStore::catalog_manifest(id)
                        .map_err(|error| WorkerError::Unsupported(error.to_string()))?;
                    let root = request
                        .models_root
                        .as_ref()
                        .unwrap_or(&self.config.paths.piper_models_dir)
                        .join(id);
                    for artifact in manifest.artifacts {
                        let path = root.join(&artifact.name);
                        identities.push(format!(
                            "{}:{}",
                            artifact.name,
                            if path.is_file() {
                                cache::sha256_file(path)?
                            } else {
                                "missing".into()
                            }
                        ));
                    }
                }
            }
            if selection.engine == "piper" {
                let (model, config) = self.selection_model_paths(request, selection);
                if !model.is_file() || !config.is_file() {
                    let id = selection
                        .model_id
                        .as_deref()
                        .unwrap_or(crate::tts_preferences::FABER_MODEL_ID);
                    if preferences.continues_native() && selection == &preferences.primary {
                        // Missing readiness is not a verified model content identity.
                        identities.push(format!("missing:{id}"));
                        continue;
                    }
                    return Err(WorkerError::Piper(format!("Piper model {id} is not installed. Install it in Models or run models install {id}.")));
                }
                // Validate before cache/recovery can bypass provider preparation.
                crate::piper::validate_model_file_quality(&model, &config)
                    .map_err(|error| WorkerError::Piper(error.to_string()))?;
                identities.push(cache::sha256_file(model)?);

                identities.push(cache::sha256_file(config)?);
            }
        }
        let material = crate::tts_session::request_cache_material(
            base_request_key,
            language,
            preferences,
            &identities,
        )
        .map_err(|error| WorkerError::Unsupported(error.to_string()))?;
        Ok(cache::sha256_bytes(material.as_bytes()))
    }
}
