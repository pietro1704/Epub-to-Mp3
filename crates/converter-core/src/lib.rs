//! Domain types for the conversion pipeline.

#[cfg(not(target_arch = "wasm32"))]
pub mod book_input;

#[cfg(not(target_arch = "wasm32"))]
pub mod adaptive;
#[cfg(not(target_arch = "wasm32"))]
pub mod audio;
#[cfg(not(target_arch = "wasm32"))]
pub mod cache;
#[cfg(not(target_arch = "wasm32"))]
pub mod config;
#[cfg(not(target_arch = "wasm32"))]
pub mod conversion_control;
#[cfg(not(target_arch = "wasm32"))]
pub mod conversion_selection;
#[cfg(not(target_arch = "wasm32"))]
pub mod desktop_tts;
#[cfg(not(target_arch = "wasm32"))]
pub mod embedded;
pub mod epub;
#[cfg(not(target_arch = "wasm32"))]
pub mod ingestion;
#[cfg(not(target_arch = "wasm32"))]
pub mod jobs;
pub mod language;
pub mod language_model_resolution;
pub mod model_catalog;
#[cfg(not(target_arch = "wasm32"))]
pub mod model_store;
pub mod narration_plan;
mod parallel_columns;
#[cfg(not(target_arch = "wasm32"))]
pub mod paths;
pub mod pcm;
#[cfg(not(target_arch = "wasm32"))]
pub mod piper;
#[cfg(not(target_arch = "wasm32"))]
pub mod platform_tts;
pub mod pronunciation;
pub mod reader;
mod speech_alignment;
pub mod speech_model_library;
mod speech_silence;
pub mod structure;
pub mod text;
pub mod toc;
#[cfg(not(target_arch = "wasm32"))]
pub mod tts;
pub mod tts_preferences;
pub mod tts_session;
#[cfg(not(target_arch = "wasm32"))]
pub mod worker;
mod zip_names;

// Exercise the production Piper decoder in the model-free workspace test gate.
#[cfg(test)]
#[allow(dead_code)]
#[path = "../../../native/vendor/piper-rs/src/model_config.rs"]
mod piper_model_config_contract;
