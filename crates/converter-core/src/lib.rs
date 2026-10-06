//! Domain types for the conversion pipeline.

#[cfg(not(target_arch = "wasm32"))]
pub mod archive;
#[cfg(not(target_arch = "wasm32"))]
pub mod audio;
#[cfg(not(target_arch = "wasm32"))]
pub mod cache;
#[cfg(not(target_arch = "wasm32"))]
pub mod config;
#[cfg(not(target_arch = "wasm32"))]
pub mod embedded;
#[cfg(not(target_arch = "wasm32"))]
pub mod engine;
pub mod epub;
#[cfg(not(target_arch = "wasm32"))]
pub mod ingestion;
#[cfg(not(target_arch = "wasm32"))]
pub mod jobs;
#[cfg(all(not(target_arch = "wasm32"), feature = "kokoro-sherpa-runtime"))]
pub mod kokoro_sherpa;
#[cfg(not(target_arch = "wasm32"))]
pub mod model_catalog;
#[cfg(not(target_arch = "wasm32"))]
pub mod model_store;
#[cfg(not(target_arch = "wasm32"))]
pub mod paths;
#[cfg(not(target_arch = "wasm32"))]
pub mod piper;
pub mod structure;
pub mod text;
pub mod toc;
#[cfg(not(target_arch = "wasm32"))]
pub mod tts;
#[cfg(not(target_arch = "wasm32"))]
pub mod tts_runtime;
#[cfg(not(target_arch = "wasm32"))]
pub mod worker;

/// Returns the core library health status.
pub fn health() -> &'static str {
    "ok"
}
