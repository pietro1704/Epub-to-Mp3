//! Domain types for the conversion pipeline.

pub mod archive;
pub mod audio;
pub mod cache;
pub mod config;
pub mod embedded;
pub mod engine;
pub mod epub;
pub mod ingestion;
pub mod jobs;
#[cfg(feature = "kokoro-sherpa-runtime")]
pub mod kokoro_sherpa;
pub mod model_catalog;
pub mod model_store;
pub mod paths;
pub mod piper;
pub mod text;
pub mod toc;
pub mod tts;
pub mod tts_runtime;
pub mod worker;

/// Returns the core library health status.
pub fn health() -> &'static str {
    "ok"
}
