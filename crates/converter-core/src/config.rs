//! Typed runtime configuration for the Rust conversion core.

use std::path::PathBuf;

use crate::paths::Paths;

/// Application configuration shared by CLI, server, and embedded runtimes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppConfig {
    pub paths: Paths,
    pub engine: String,
    pub expected_wpm: u32,
    pub max_chapter_chars: Option<usize>,
    pub edge_chunk_chars: usize,
    pub edge_max_segment_seconds: u32,
    pub max_parallel: usize,
    pub fallback_engine: Option<String>,
}
impl AppConfig {
    /// Build configuration from environment variables and resolved paths.
    pub fn from_env() -> Self {
        let paths = crate::paths::resolve_paths();
        Self::from_paths(paths)
    }

    pub fn from_paths(paths: Paths) -> Self {
        Self {
            paths,
            engine: env_string("ENGINE", "auto"),
            expected_wpm: env_parse("EXPECTED_WPM", 200),
            max_chapter_chars: env_optional_parse("MAX_CHAPTER_CHARS"),
            edge_chunk_chars: env_parse(
                "EDGE_CHUNK_CHARS",
                if cfg!(target_os = "android") {
                    4_096
                } else {
                    12_000
                },
            ),
            edge_max_segment_seconds: env_parse("EDGE_MAX_SEGMENT_SECONDS", 85),
            max_parallel: env_parse(
                "MAX_PARALLEL",
                if cfg!(target_os = "android") {
                    1
                } else {
                    std::thread::available_parallelism().map_or(1, |n| n.get())
                },
            ),
            fallback_engine: env_optional_string("FALLBACK_ENGINE"),
        }
    }

    pub fn cache_path(&self, parts: &[&str]) -> Result<PathBuf, crate::paths::PathError> {
        self.paths.cache_path(parts.iter().collect::<PathBuf>())
    }

    pub fn output_path(&self, parts: &[&str]) -> Result<PathBuf, crate::paths::PathError> {
        self.paths.output_path(parts.iter().collect::<PathBuf>())
    }
}

fn env_string(key: &str, default: &str) -> String {
    std::env::var(key)
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| default.into())
}

fn env_parse<T: std::str::FromStr>(key: &str, default: T) -> T {
    std::env::var(key)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn env_optional_parse<T: std::str::FromStr>(key: &str) -> Option<T> {
    std::env::var(key)
        .ok()
        .filter(|value| !value.is_empty())
        .and_then(|value| value.parse().ok())
}

fn env_optional_string(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|value| !value.is_empty())
}
