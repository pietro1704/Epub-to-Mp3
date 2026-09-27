//! Domain types for the conversion pipeline.

pub mod cache;
pub mod config;
pub mod epub;
pub mod ingestion;
pub mod paths;
pub mod piper;
pub mod text;
pub mod toc;

/// Returns the core library health status.
pub fn health() -> &'static str {
    "ok"
}
