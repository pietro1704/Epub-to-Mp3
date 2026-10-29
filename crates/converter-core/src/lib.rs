//! Domain types for the conversion pipeline.

#[cfg(not(target_arch = "wasm32"))]
pub mod adaptive;
#[cfg(not(target_arch = "wasm32"))]
pub mod archive;
#[cfg(not(target_arch = "wasm32"))]
pub mod audio;
#[cfg(not(target_arch = "wasm32"))]
pub mod cache;
#[cfg(not(target_arch = "wasm32"))]
pub mod config;
#[cfg(not(target_arch = "wasm32"))]
pub mod conversion_control;
#[cfg(not(target_arch = "wasm32"))]
pub mod desktop_tts;
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
pub mod model_catalog;
#[cfg(not(target_arch = "wasm32"))]
pub mod model_store;
#[cfg(not(target_arch = "wasm32"))]
pub mod paths;
pub mod pcm;
#[cfg(not(target_arch = "wasm32"))]
pub mod piper;
#[cfg(not(target_arch = "wasm32"))]
pub mod platform_tts;
pub mod pronunciation;
pub mod speech_model_library;
pub mod structure;
pub mod text;
pub mod toc;
#[cfg(not(target_arch = "wasm32"))]
pub mod tts;
pub mod tts_preferences;
#[cfg(not(target_arch = "wasm32"))]
pub mod tts_runtime;
pub mod tts_session;
#[cfg(not(target_arch = "wasm32"))]
pub mod worker;
mod zip_names;

/// Returns the core library health status.
pub fn health() -> &'static str {
    "ok"
}

// Exercise the production Piper decoder in the model-free workspace test gate.
#[cfg(test)]
#[allow(dead_code)]
#[path = "../../../native/vendor/piper-rs/src/model_config.rs"]
mod piper_model_config_contract;
