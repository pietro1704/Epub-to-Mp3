//! Offline installed-state and runtime-readiness projection for catalogue v3.

use super::*;
use crate::model_store::{InstalledModelState, ModelStore};

impl SpeechModelLibrary {
    pub fn snapshot_with_inspection(
        &self,
        query: CatalogQuery,
        store: &ModelStore,
        readiness: &[RuntimeReadinessObservation],
    ) -> Result<SpeechModelSnapshot, CatalogError> {
        validate_readiness(readiness)?;
        let mut snapshot = self.snapshot(query)?;
        for entry in &mut snapshot.entries {
            if !entry.distribution.installable {
                entry.installation.state = InstallationState::NotApplicable;
                entry.readiness.state = ReadinessState::NotApplicable;
                entry.selection = selection_for(entry);
                continue;
            }

            let manifest = ModelStore::catalog_manifest(&entry.identity.model_id)
                .map_err(|error| CatalogError::Invalid(error.to_string()))?;
            let inspection = store
                .inspect_manifest(&manifest)
                .map_err(|error| CatalogError::Invalid(error.to_string()))?;
            entry.installation = InstallationStatus {
                state: match inspection.state {
                    InstalledModelState::Missing => InstallationState::Missing,
                    InstalledModelState::Corrupted => InstallationState::Corrupted,
                    InstalledModelState::StaleRevision => InstallationState::StaleRevision,
                    InstalledModelState::Verified => InstallationState::Installed,
                },
                verified_revision: inspection.verified_revision,
                installed_bytes: inspection.installed_bytes,
            };
            entry.distribution.installed_bytes = entry.installation.installed_bytes;

            let matching = readiness
                .iter()
                .filter(|observation| {
                    observation.model_id == entry.identity.model_id
                        && observation.model_revision == entry.identity.model_revision
                })
                .collect::<Vec<_>>();
            if matching.len() > 1 {
                return Err(CatalogError::Invalid(format!(
                    "duplicate runtime readiness for {}",
                    entry.identity.model_id
                )));
            }
            if let Some(observation) = matching.first() {
                entry.readiness = match &observation.outcome {
                    RuntimeReadinessOutcome::Ready {
                        active_runtime_revision,
                    } => ReadinessStatus {
                        state: ReadinessState::Ready,
                        active_runtime_revision: Some(active_runtime_revision.clone()),
                        failure: None,
                    },
                    RuntimeReadinessOutcome::Unavailable { failure } => ReadinessStatus {
                        state: ReadinessState::Unavailable,
                        active_runtime_revision: None,
                        failure: Some(*failure),
                    },
                };
            }
            entry.selection = selection_for(entry);
        }
        Ok(snapshot)
    }
}

fn validate_readiness(readiness: &[RuntimeReadinessObservation]) -> Result<(), CatalogError> {
    for observation in readiness {
        if observation.model_id.trim().is_empty()
            || observation
                .model_revision
                .as_deref()
                .is_some_and(|revision| revision.trim().is_empty())
            || matches!(
                &observation.outcome,
                RuntimeReadinessOutcome::Ready {
                    active_runtime_revision
                } if active_runtime_revision.trim().is_empty()
            )
        {
            return Err(CatalogError::Invalid(
                "runtime readiness contains an empty identity".into(),
            ));
        }
    }
    Ok(())
}

pub(super) fn selection_for(entry: &SpeechModelEntry) -> SelectionAvailability {
    let mut reasons = Vec::new();
    if !entry.compatibility.compatible {
        reasons.push(SelectionReason::Incompatible);
    }
    if !entry.distribution.installable {
        reasons.push(SelectionReason::NotInstallable);
    } else {
        match entry.installation.state {
            InstallationState::NotInspected => {
                reasons.push(SelectionReason::InstallationNotInspected)
            }
            InstallationState::Missing => reasons.push(SelectionReason::InstallationMissing),
            InstallationState::Corrupted => reasons.push(SelectionReason::InstallationCorrupted),
            InstallationState::StaleRevision => {
                reasons.push(SelectionReason::InstallationStaleRevision)
            }
            InstallationState::NotApplicable | InstallationState::Installed => {}
        }
        match entry.readiness.state {
            ReadinessState::NotInspected => reasons.push(SelectionReason::ReadinessNotInspected),
            ReadinessState::Unavailable => reasons.push(SelectionReason::RuntimeUnavailable),
            ReadinessState::NotApplicable | ReadinessState::Ready => {}
        }
    }
    SelectionAvailability {
        selectable: reasons.is_empty(),
        reasons,
    }
}
