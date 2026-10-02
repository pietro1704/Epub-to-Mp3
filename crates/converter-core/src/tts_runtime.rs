//! Runtime capability checks for optional embedded TTS engines.
//!
//! Model metadata alone is not sufficient to claim that an engine can
//! synthesize audio. This module keeps the distinction explicit and shared by
//! every client adapter.

use std::path::{Path, PathBuf};

use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RuntimeCapability {
    pub engine: &'static str,
    pub model_id: &'static str,
    pub installed: bool,
    pub inference_ready: bool,
    pub reason: Option<String>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum RuntimeError {
    #[error("unsupported TTS runtime: {0}")]
    UnsupportedEngine(String),
    #[error("model is not installed: {0}")]
    ModelNotInstalled(PathBuf),
    #[error("TTS runtime is not available: {0}")]
    RuntimeUnavailable(String),
}

/// Checks the on-disk Kokoro model layout without loading a native runtime.
///
/// Returning `inference_ready = false` is intentional until the ONNX session,
/// tokenizer, phonemizer, and WAV encoder are implemented and exercised.
pub fn inspect_runtime(engine: &str, model_root: &Path) -> Result<RuntimeCapability, RuntimeError> {
    if engine != "kokoro" {
        return Err(RuntimeError::UnsupportedEngine(engine.to_owned()));
    }

    let required = [
        model_root.join("onnx/model_quantized.onnx"),
        model_root.join("config.json"),
        model_root.join("tokenizer.json"),
        model_root.join("tokenizer_config.json"),
        model_root.join("voices/af.bin"),
    ];
    let missing: Vec<_> = required.iter().filter(|path| !path.is_file()).collect();
    if !missing.is_empty() {
        return Ok(RuntimeCapability {
            engine: "kokoro",
            model_id: "kokoro-82m",
            installed: false,
            inference_ready: false,
            reason: Some(format!("missing artifact: {}", missing[0].display())),
        });
    }

    Ok(RuntimeCapability {
        engine: "kokoro",
        model_id: "kokoro-82m",
        installed: true,
        inference_ready: false,
        reason: Some("Kokoro inference runtime is not compiled yet".to_owned()),
    })
}

pub fn synthesize_kokoro(_model_root: &Path, _text: &str) -> Result<Vec<u8>, RuntimeError> {
    Err(RuntimeError::RuntimeUnavailable(
        "Kokoro inference runtime is not compiled yet".to_owned(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn reports_missing_kokoro_artifact_without_claiming_readiness() {
        let root = tempdir().unwrap();
        let capability = inspect_runtime("kokoro", root.path()).unwrap();
        assert!(!capability.installed);
        assert!(!capability.inference_ready);
        assert!(capability.reason.unwrap().contains("missing artifact"));
    }

    #[test]
    fn installed_model_remains_unavailable_until_inference_is_verified() {
        let root = tempdir().unwrap();
        for relative in [
            "onnx/model_quantized.onnx",
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "voices/af.bin",
        ] {
            let path = root.path().join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, b"test").unwrap();
        }
        let capability = inspect_runtime("kokoro", root.path()).unwrap();
        assert!(capability.installed);
        assert!(!capability.inference_ready);
        assert_eq!(
            synthesize_kokoro(root.path(), "hello").unwrap_err(),
            RuntimeError::RuntimeUnavailable("Kokoro inference runtime is not compiled yet".into())
        );
    }
}
