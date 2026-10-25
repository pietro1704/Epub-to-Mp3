use crate::model_catalog::{
    ExactLanguageDescriptor, LicenceDescriptor, ModelPlatform, ModelPresentationDescriptor,
    TtsArtifactDescriptor,
};
use crate::tts_session::{ProviderDescriptor, SessionSelection};
use serde::Serialize;

pub const SCHEMA_VERSION: u32 = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogQuery {
    pub language: String,
    pub platform: ModelPlatform,
    pub android_api: Option<u32>,
    pub architecture: String,
    pub os_version: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SpeechModelSnapshot {
    pub schema_version: u32,
    pub synthesis_contract_version: u32,
    pub generated_from_catalog_revision: String,
    pub target: CatalogTarget,
    pub default_selection: SessionSelection,
    pub providers: Vec<ProviderDescriptor>,
    pub entries: Vec<SpeechModelEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CatalogTarget {
    pub language: String,
    pub platform: &'static str,
    pub android_api: Option<u32>,
    pub architecture: String,
    pub os_version: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SpeechModelEntry {
    pub identity: ModelIdentity,
    pub presentation: ModelPresentationDescriptor,
    pub language_evidence: LanguageEvidence,
    pub distribution: Distribution,
    pub licence: LicenceDescriptor,
    pub compatibility: Compatibility,
    pub installation: InstallationStatus,
    pub readiness: ReadinessStatus,
    pub selection: SelectionAvailability,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ModelIdentity {
    pub provider: String,
    pub runtime: Option<String>,
    pub model_id: String,
    pub model_revision: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LanguageEvidence {
    pub routing_tags: Vec<String>,
    pub exact_tags: Vec<ExactLanguageDescriptor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Distribution {
    pub installable: bool,
    pub artifacts: Vec<TtsArtifactDescriptor>,
    pub download_bytes: Option<u64>,
    pub installed_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SelectionAvailability {
    pub selectable: bool,
    pub reasons: Vec<SelectionReason>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SelectionReason {
    Incompatible,
    NotInstallable,
    InstallationNotInspected,
    InstallationMissing,
    InstallationCorrupted,
    InstallationStaleRevision,
    ReadinessNotInspected,
    RuntimeUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Compatibility {
    pub compatible: bool,
    pub reasons: Vec<CompatibilityReason>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CompatibilityReason {
    UnsupportedLanguage,
    UnsupportedPlatform,
    AndroidApiTooLow,
    QualityDisabled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InstallationStatus {
    pub state: InstallationState,
    pub verified_revision: Option<String>,
    pub installed_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReadinessStatus {
    pub state: ReadinessState,
    pub active_runtime_revision: Option<String>,
    pub failure: Option<ReadinessFailure>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallationState {
    NotInspected,
    NotApplicable,
    Missing,
    Corrupted,
    StaleRevision,
    Installed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadinessState {
    NotInspected,
    NotApplicable,
    Ready,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadinessFailure {
    RuntimeUnavailable,
    RuntimeRejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeReadinessObservation {
    pub model_id: String,
    pub model_revision: Option<String>,
    pub outcome: RuntimeReadinessOutcome,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeReadinessOutcome {
    Ready { active_runtime_revision: String },
    Unavailable { failure: ReadinessFailure },
}

pub(super) fn platform_name(platform: ModelPlatform) -> &'static str {
    match platform {
        ModelPlatform::Android => "android",
        ModelPlatform::Ios => "ios",
        ModelPlatform::Macos => "macos",
        ModelPlatform::Linux => "linux",
        ModelPlatform::Windows => "windows",
    }
}
