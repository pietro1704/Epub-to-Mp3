//! Domain types for the conversion pipeline.

pub mod config;
pub mod paths;
pub mod text;

/// Returns the core library health status.
pub fn health() -> &'static str {
    "ok"
}
