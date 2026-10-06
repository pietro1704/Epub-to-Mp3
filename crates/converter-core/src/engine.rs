//! Policy and orchestration seam for the conversion engine.
//!
//! This module deliberately does not know how EPUB parsing, synthesis, caching,
//! or audio assembly work. It supplies the typed decisions and lifecycle hooks
//! that an adapter can connect to those existing implementations.

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::piper::CancellationToken;

/// Ordered fallback levels. Lower values are attempted first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FallbackTier {
    Primary,
    Secondary,
    Offline,
}

/// A local or online synthesis engine candidate in fallback order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EngineCandidate {
    pub name: String,
    pub tier: FallbackTier,
}

/// Explicit resource and fallback policy for one conversion.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EnginePolicy {
    pub candidates: Vec<EngineCandidate>,
    pub concurrency: ConcurrencySettings,
    pub cancellation: CancellationSettings,
}

impl Default for EnginePolicy {
    fn default() -> Self {
        Self {
            candidates: vec![EngineCandidate {
                name: "edge".into(),
                tier: FallbackTier::Primary,
            }],
            concurrency: ConcurrencySettings::default(),
            cancellation: CancellationSettings::default(),
        }
    }
}

impl EnginePolicy {
    pub fn candidates_in_order(&self) -> impl Iterator<Item = &EngineCandidate> {
        self.candidates.iter()
    }
}

/// Bounds chapter work without coupling the seam to a particular executor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConcurrencySettings {
    pub max_chapters: usize,
    pub max_in_flight: usize,
    pub preserve_order: bool,
}

impl Default for ConcurrencySettings {
    fn default() -> Self {
        let cpus = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1);
        Self {
            max_chapters: cpus,
            max_in_flight: cpus,
            preserve_order: true,
        }
    }
}

/// Cancellation behavior exposed to workers and adapters.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CancellationSettings {
    pub poll_interval_ms: u64,
    pub allow_finish_current_chunk: bool,
}

impl Default for CancellationSettings {
    fn default() -> Self {
        Self {
            poll_interval_ms: 50,
            allow_finish_current_chunk: true,
        }
    }
}

/// Stable progress messages emitted by orchestration, not by an engine.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProgressEvent {
    Started {
        total_chapters: usize,
    },
    ChapterStarted {
        chapter_index: usize,
        total_chapters: usize,
    },
    BackendSelected {
        chapter_index: usize,
        backend: String,
        tier: FallbackTier,
    },
    ChapterCompleted {
        chapter_index: usize,
        total_chapters: usize,
    },
    Fallback {
        chapter_index: usize,
        failed_backend: String,
        next_backend: String,
    },
    Cancelled,
    Completed,
}

pub type ProgressSink = Arc<dyn Fn(ProgressEvent) + Send + Sync>;

/// Adapter seam for parser/TTS/cache/audio implementations.
///
/// The engine owns policy and lifecycle; adapters own I/O and runtime details.
pub trait ConversionWorker: Send + Sync {
    type Input: Send + Sync;
    type Output: Send;
    type Error: Send;

    fn convert_chapter(
        &self,
        input: &Self::Input,
        backend: &EngineCandidate,
        cancellation: &CancellationToken,
    ) -> Result<Self::Output, Self::Error>;
}

/// Policy-only coordinator. Scheduling is intentionally delegated to callers.
pub struct Engine<W> {
    worker: W,
    policy: EnginePolicy,
    cancellation: CancellationToken,
    progress: Option<ProgressSink>,
}

impl<W> Engine<W> {
    pub fn new(worker: W, policy: EnginePolicy) -> Self {
        Self {
            worker,
            policy,
            cancellation: CancellationToken::default(),
            progress: None,
        }
    }

    pub fn with_progress(mut self, sink: ProgressSink) -> Self {
        self.progress = Some(sink);
        self
    }

    pub fn worker(&self) -> &W {
        &self.worker
    }
    pub fn policy(&self) -> &EnginePolicy {
        &self.policy
    }
    pub fn cancellation(&self) -> CancellationToken {
        self.cancellation.clone()
    }
    pub fn cancel(&self) {
        self.cancellation.cancel();
    }

    pub fn emit(&self, event: ProgressEvent) {
        if let Some(sink) = &self.progress {
            sink(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_policy_does_not_select_an_uninstalled_offline_engine() {
        let policy = EnginePolicy::default();
        assert_eq!(
            policy
                .candidates_in_order()
                .map(|candidate| candidate.name.as_str())
                .collect::<Vec<_>>(),
            vec!["edge"]
        );
    }
}
