//! Runtime capability checks for optional embedded TTS engines.
//!
//! Model metadata alone is not sufficient to claim that an engine can
//! synthesize audio. This module keeps the distinction explicit and shared by
//! every client adapter.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
};

use serde::Serialize;
use thiserror::Error;

#[cfg(feature = "kokoro-tract-runtime")]
use tract_onnx::prelude::{Framework, InferenceModelExt, IntoRunnable};

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

/// Converts common espeak IPA spellings into Kokoro's Misaki symbols.
pub fn normalize_kokoro_english_phonemes(ipa: &str) -> String {
    let mut result = ipa.replace('\u{0361}', "^");
    for (from, to) in [
        ("a^ɪ", "I"),
        ("a^ʊ", "W"),
        ("d^ʒ", "ʤ"),
        ("e^ɪ", "A"),
        ("t^ʃ", "ʧ"),
        ("ɔ^ɪ", "Y"),
        ("ə^l", "ᵊl"),
        ("ʔn", "tᵊn"),
        ("ɚ", "əɹ"),
        ("e", "A"),
        ("r", "ɹ"),
        ("x", "k"),
        ("ç", "k"),
        ("ɐ", "ə"),
        ("ɬ", "l"),
        ("ʔ", "t"),
        ("ʲ", ""),
        ("\u{0303}", ""),
    ] {
        result = result.replace(from, to);
    }
    result
        .replace("o^ʊ", "O")
        .replace("ɜːɹ", "ɜɹ")
        .replace("ɜː", "ɜɹ")
        .replace("ɪə", "iə")
        .replace('ː', "")
        .replace('^', "")
}

#[derive(Debug, Clone)]
pub struct KokoroTokenizer {
    vocab: HashMap<String, i64>,
    bos_id: i64,
    eos_id: i64,
    max_length: usize,
    max_token_chars: usize,
}

impl KokoroTokenizer {
    pub fn from_json(value: &str, max_length: usize) -> Result<Self, RuntimeError> {
        let document: serde_json::Value = serde_json::from_str(value).map_err(|error| {
            RuntimeError::RuntimeUnavailable(format!("invalid tokenizer: {error}"))
        })?;
        let object = document
            .get("model")
            .and_then(|model| model.get("vocab"))
            .and_then(serde_json::Value::as_object)
            .ok_or_else(|| RuntimeError::RuntimeUnavailable("tokenizer vocab is missing".into()))?;
        let vocab: HashMap<_, _> = object
            .iter()
            .filter_map(|(token, id)| id.as_i64().map(|id| (token.clone(), id)))
            .collect();
        let bos_id = *vocab.get("$").ok_or_else(|| {
            RuntimeError::RuntimeUnavailable("tokenizer BOS token is missing".into())
        })?;
        let max_token_chars = vocab
            .keys()
            .map(|token| token.chars().count())
            .max()
            .unwrap_or(1);
        Ok(Self {
            vocab,
            bos_id,
            eos_id: bos_id,
            max_length,
            max_token_chars,
        })
    }

    pub fn encode_phonemes(&self, phonemes: &str) -> Result<Vec<i64>, RuntimeError> {
        let chars: Vec<_> = phonemes.chars().collect();
        let mut tokens = vec![self.bos_id];
        let mut index = 0;
        while index < chars.len() && tokens.len() + 1 < self.max_length {
            let limit = self.max_token_chars.min(chars.len() - index);
            let mut matched = None;
            for length in (1..=limit).rev() {
                let token: String = chars[index..index + length].iter().collect();
                if let Some(id) = self.vocab.get(&token) {
                    matched = Some((length, *id));
                    break;
                }
            }
            if let Some((length, id)) = matched {
                tokens.push(id);
                index += length;
            } else if chars[index].is_whitespace() {
                index += 1;
            } else {
                return Err(RuntimeError::RuntimeUnavailable(format!(
                    "tokenizer does not contain phoneme {:?}",
                    chars[index]
                )));
            }
        }
        tokens.push(self.eos_id);
        Ok(tokens)
    }
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

    #[cfg(feature = "kokoro-tract-runtime")]
    let runtime_error = match tract_onnx::onnx()
        .model_for_path(model_root.join("onnx/model_quantized.onnx"))
        .and_then(|model| model.into_optimized())
        .and_then(|model| model.into_runnable())
    {
        Ok(_) => None,
        Err(error) => Some(format!("tract ONNX session unavailable: {error}")),
    };

    #[cfg(not(feature = "kokoro-tract-runtime"))]
    let runtime_error =
        Some("Kokoro inference runtime requires a maintained embedded ONNX integration".to_owned());

    Ok(RuntimeCapability {
        engine: "kokoro",
        model_id: "kokoro-82m",
        installed: true,
        inference_ready: runtime_error.is_none(),
        reason: runtime_error,
    })
}

pub fn synthesize_kokoro(_model_root: &Path, _text: &str) -> Result<Vec<u8>, RuntimeError> {
    let _ = (_model_root, _text);
    Err(RuntimeError::RuntimeUnavailable(
        "Kokoro inference runtime requires a maintained ONNX Runtime integration".to_owned(),
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
    fn normalizes_common_kokoro_english_ipa_symbols() {
        assert_eq!(normalize_kokoro_english_phonemes("t^ʃ e^ɪɚ"), "ʧ Aəɹ");
    }

    #[test]
    fn tokenizes_with_longest_match_and_bos_eos() {
        let tokenizer =
            KokoroTokenizer::from_json(r#"{"model":{"vocab":{"$":0,"a":1,"ab":2,"b":3}}}"#, 16)
                .unwrap();
        assert_eq!(tokenizer.encode_phonemes("ab a").unwrap(), vec![0, 2, 1, 0]);
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
            RuntimeError::RuntimeUnavailable(
                "Kokoro inference runtime requires a maintained ONNX Runtime integration".into(),
            )
        );
    }
}
