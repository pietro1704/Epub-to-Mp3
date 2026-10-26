//! Versioned synthesis seam shared by native adapters and browser bindings.
//!
//! Preparation never installs assets. A session pins the resolved identity;
//! cancellation and generation replacement reject late audio before publication.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const CONTRACT_VERSION: u32 = 2;
pub const MAX_SEGMENT_BYTES: usize = 16 * 1024 * 1024;
mod recovery;
pub use recovery::RecoveryAttempt;
mod catalog;
pub use catalog::{builtin_descriptors, catalog_json, runtime_for};
mod registry;
pub use registry::TtsRegistry;
mod text;
pub use text::segment_text;
pub(crate) use text::segment_text_protecting;
mod listening;
pub use listening::{ListeningPlan, ListeningPosition, PlaybackFeedback};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "encoding", rename_all = "snake_case", deny_unknown_fields)]
pub enum AudioFormat {
    Mp3,
    WavPcm16,
    Pcm16 { sample_rate: u32, channels: u16 },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionSelection {
    pub version: u32,
    pub provider: String,
    pub runtime: String,
    pub model_id: Option<String>,
    pub model_revision: Option<String>,
    pub voice: Option<String>,
    #[serde(default)]
    pub options: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedIdentity {
    pub selection: SessionSelection,
    pub runtime_revision: String,
    pub artifacts: BTreeMap<String, String>,
    /// Opaque platform voices cannot safely participate in persistent cache reuse.
    pub reusable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SynthesisReceipt {
    pub version: u32,
    #[serde(default)]
    pub session_id: String,
    pub source_index: usize,
    pub segment_index: usize,
    pub identity: ResolvedIdentity,
    pub format: AudioFormat,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_cause: Option<TtsFailure>,
}

pub fn new_session_id() -> String {
    #[cfg(not(target_arch = "wasm32"))]
    {
        format!("{:032x}", rand::random::<u128>())
    }
    #[cfg(target_arch = "wasm32")]
    {
        static SEQUENCE: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        format!(
            "{:x}-{:x}-{:x}",
            js_sys::Date::now() as u64,
            (js_sys::Math::random() * u64::MAX as f64) as u64,
            SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TtsCapabilities {
    pub audio_formats: Vec<AudioFormat>,
    pub languages: Vec<String>,
    pub voices: Vec<String>,
    pub voice_selection: bool,
    /// Adapters validate option values during preparation; unknown keys fail here.
    pub configurable_options: Vec<String>,
    pub max_text_chars: usize,
    pub cancellation: CancellationCapability,
    pub streaming: bool,
    pub audio_bytes: bool,
    pub online: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CancellationCapability {
    Cooperative,
    AfterCall,
    TerminateWorker,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderDescriptor {
    pub provider: String,
    pub runtime: String,
    pub revision: String,
    pub targets: Vec<String>,
    pub capabilities: TtsCapabilities,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    Unavailable,
    InvalidSelection,
    InvalidAudio,
    Synthesis,
    RateLimited,
    Cancelled,
    Replaced,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TtsFailure {
    pub kind: FailureKind,
    pub message: String,
    pub retry_after_ms: Option<u64>,
}
impl TtsFailure {
    pub fn new(kind: FailureKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            retry_after_ms: None,
        }
    }
    pub fn terminal(&self) -> bool {
        matches!(self.kind, FailureKind::Cancelled | FailureKind::Replaced)
    }
}
impl std::fmt::Display for TtsFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}
impl std::error::Error for TtsFailure {}

pub struct SynthesisContext<'a> {
    pub language: &'a str,
    pub cancelled: &'a (dyn Fn() -> bool + Sync),
    pub replaced: &'a (dyn Fn() -> bool + Sync),
}
impl SynthesisContext<'_> {
    pub fn check(&self) -> Result<(), TtsFailure> {
        if (self.cancelled)() {
            Err(TtsFailure::new(
                FailureKind::Cancelled,
                "Conversion cancelled",
            ))
        } else if (self.replaced)() {
            Err(TtsFailure::new(
                FailureKind::Replaced,
                "Playback window changed",
            ))
        } else {
            Ok(())
        }
    }
}

/// A bounded sink prevents an adapter from publishing unvalidated audio directly.
pub struct AudioSink {
    format: AudioFormat,
    bytes: Vec<u8>,
    limit: usize,
}
impl AudioSink {
    pub fn new(format: AudioFormat, limit: usize) -> Self {
        Self {
            format,
            bytes: Vec::new(),
            limit: limit.min(MAX_SEGMENT_BYTES),
        }
    }
    pub fn write(&mut self, bytes: &[u8]) -> Result<(), TtsFailure> {
        if bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
            return Err(TtsFailure::new(
                FailureKind::InvalidAudio,
                "Segment audio exceeds its byte limit",
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }
    pub fn into_mp3(self) -> Result<Vec<u8>, TtsFailure> {
        normalize_audio(&self.format, &self.bytes)
    }
}

pub fn normalize_audio(format: &AudioFormat, bytes: &[u8]) -> Result<Vec<u8>, TtsFailure> {
    let invalid = |message| TtsFailure::new(FailureKind::InvalidAudio, message);
    if bytes.len() > MAX_SEGMENT_BYTES {
        return Err(invalid("Segment audio exceeds its byte limit".into()));
    }
    match format {
        AudioFormat::Mp3 => {
            crate::pcm::validate_mp3(bytes).map_err(invalid)?;
            Ok(bytes.to_vec())
        }
        AudioFormat::WavPcm16 => crate::pcm::encode_wav_mp3(bytes).map_err(invalid),
        AudioFormat::Pcm16 {
            sample_rate,
            channels,
        } => {
            if *channels != 1
                || !(8_000..=96_000).contains(sample_rate)
                || bytes.is_empty()
                || bytes.len() % 2 != 0
            {
                return Err(invalid(
                    "Expected mono signed 16-bit PCM at 8–96 kHz".into(),
                ));
            }
            let mut wav = Vec::with_capacity(bytes.len() + 44);
            wav.extend_from_slice(b"RIFF");
            wav.extend_from_slice(&(36 + bytes.len() as u32).to_le_bytes());
            wav.extend_from_slice(b"WAVEfmt \x10\0\0\0\x01\0\x01\0");
            wav.extend_from_slice(&sample_rate.to_le_bytes());
            wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
            wav.extend_from_slice(b"\x02\0\x10\0data");
            wav.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            wav.extend_from_slice(bytes);
            crate::pcm::encode_wav_mp3(&wav).map_err(invalid)
        }
    }
}

pub fn encode_pcm_f32(samples: &[f32], sample_rate: u32) -> Result<Vec<u8>, TtsFailure> {
    if samples.len() > MAX_SEGMENT_BYTES / 2 || samples.iter().any(|sample| !sample.is_finite()) {
        return Err(TtsFailure::new(
            FailureKind::InvalidAudio,
            "Invalid or unbounded float PCM",
        ));
    }
    let pcm: Vec<_> = samples
        .iter()
        .flat_map(|sample| ((sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes())
        .collect();
    normalize_audio(
        &AudioFormat::Pcm16 {
            sample_rate,
            channels: 1,
        },
        &pcm,
    )
}

pub trait TtsProvider: Send + Sync {
    fn descriptor(&self) -> ProviderDescriptor;
    fn prepare(
        &self,
        selection: &SessionSelection,
        language: &str,
    ) -> Result<Box<dyn TtsSession>, TtsFailure>;
}
pub trait TtsSession: Send {
    fn identity(&self) -> &ResolvedIdentity;
    fn synthesize(
        &mut self,
        text: &str,
        context: &SynthesisContext<'_>,
        sink: &mut AudioSink,
    ) -> Result<(), TtsFailure>;
}

/// Order-independent, versioned material for hashing at a persistence adapter.
/// The source includes the exact chapter/range and normalized text identity.
pub fn cache_material(
    source: &str,
    text_revision: &str,
    identity: &ResolvedIdentity,
    format: &AudioFormat,
) -> Result<String, TtsFailure> {
    if !identity.reusable {
        return Err(TtsFailure::new(
            FailureKind::Unavailable,
            "Resolved voice identity is not reusable",
        ));
    }
    serde_json::to_string(&(CONTRACT_VERSION, source, text_revision, identity, format))
        .map_err(|error| TtsFailure::new(FailureKind::InvalidSelection, error.to_string()))
}

/// Canonical request identity used by native and WASM persistence adapters.
pub fn request_cache_material(
    source: &str,
    language: Option<&str>,
    preferences: &crate::tts_preferences::TtsPreferences,
    identities: &[String],
) -> Result<String, TtsFailure> {
    serde_json::to_string(&(
        CONTRACT_VERSION,
        "text-v1",
        source,
        language,
        preferences,
        identities,
    ))
    .map_err(|error| TtsFailure::new(FailureKind::InvalidSelection, error.to_string()))
}

#[cfg(test)]
mod tests;
