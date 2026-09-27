//! Domain types for the conversion pipeline.

pub mod archive;
pub mod audio;
pub mod cache;
pub mod config;
pub mod epub;
pub mod ingestion;
pub mod jobs;
pub mod paths;
pub mod piper;
pub mod text;
pub mod tts;
pub mod toc;

/// Returns the core library health status.
pub fn health() -> &'static str {
    "ok"
}
