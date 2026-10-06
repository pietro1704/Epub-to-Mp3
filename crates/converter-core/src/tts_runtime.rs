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
use tract_onnx::prelude::{tvec, Framework, InferenceModelExt, IntoRunnable, IntoTValue, Tensor};

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
            } else if chars[index].is_whitespace() || chars[index] == '\u{200d}' {
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

#[cfg(feature = "kokoro-tract-runtime")]
pub fn phonemize_kokoro_english(text: &str) -> Result<String, RuntimeError> {
    let phonemizer = misaki_rs::G2P::new(misaki_rs::Language::EnglishUS);
    let (phonemes, _) = phonemizer.g2p(text).map_err(|error| {
        RuntimeError::RuntimeUnavailable(format!("Misaki phonemization failed: {error}"))
    })?;
    if phonemes.trim().is_empty() {
        return Err(RuntimeError::RuntimeUnavailable(
            "Misaki returned no phonemes".to_owned(),
        ));
    }
    Ok(normalize_kokoro_english_phonemes(&phonemes))
}

#[cfg(feature = "kokoro-tract-runtime")]
fn load_kokoro_voice_style(
    model_root: &Path,
    token_count: usize,
) -> Result<Vec<f32>, RuntimeError> {
    const STYLE_DIM: usize = 256;
    let bytes = std::fs::read(model_root.join("voices/af.bin")).map_err(|error| {
        RuntimeError::RuntimeUnavailable(format!("failed to read Kokoro voice: {error}"))
    })?;
    if bytes.len() % (STYLE_DIM * std::mem::size_of::<f32>()) != 0 {
        return Err(RuntimeError::RuntimeUnavailable(
            "Kokoro voice file has an invalid size".to_owned(),
        ));
    }
    let rows = bytes.len() / (STYLE_DIM * std::mem::size_of::<f32>());
    let row = token_count.min(rows.saturating_sub(1));
    let start = row * STYLE_DIM * std::mem::size_of::<f32>();
    let style = bytes[start..start + STYLE_DIM * std::mem::size_of::<f32>()]
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect::<Vec<_>>();
    if style.iter().any(|value| !value.is_finite()) {
        return Err(RuntimeError::RuntimeUnavailable(
            "Kokoro voice contains non-finite values".to_owned(),
        ));
    }
    Ok(style)
}

/// Checks the on-disk Kokoro model layout without loading a native runtime.
///
/// Returning `inference_ready = false` is intentional until the ONNX session,
/// tokenizer, phonemizer, and WAV encoder are implemented and exercised.
pub fn inspect_runtime(engine: &str, model_root: &Path) -> Result<RuntimeCapability, RuntimeError> {
    if engine != "kokoro" {
        return Err(RuntimeError::UnsupportedEngine(engine.to_owned()));
    }

    #[cfg(feature = "kokoro-sherpa-runtime")]
    let required = [
        if model_root.join("model.int8.onnx").is_file() {
            model_root.join("model.int8.onnx")
        } else {
            model_root.join("model.onnx")
        },
        model_root.join("tokens.txt"),
        model_root.join("voices.bin"),
        model_root.join("espeak-ng-data"),
    ];
    #[cfg(not(feature = "kokoro-sherpa-runtime"))]
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
        Ok(_) => phonemize_kokoro_english("Hello world")
            .map(|_| ())
            .map_err(|error| error.to_string())
            .err(),
        Err(error) => Some(format!("tract ONNX session unavailable: {error}")),
    };

    #[cfg(feature = "kokoro-sherpa-runtime")]
    let runtime_error = crate::kokoro_sherpa::synthesize_wav(model_root, "Hello world")
        .map(|_| ())
        .map_err(|error| error.to_string())
        .err();

    #[cfg(all(
        not(feature = "kokoro-sherpa-runtime"),
        not(feature = "kokoro-tract-runtime")
    ))]
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

#[cfg(feature = "kokoro-tract-runtime")]
pub fn synthesize_kokoro(model_root: &Path, text: &str) -> Result<Vec<u8>, RuntimeError> {
    let phonemes = phonemize_kokoro_english(text)?;
    let tokenizer = KokoroTokenizer::from_json(
        &std::fs::read_to_string(model_root.join("tokenizer.json")).map_err(|error| {
            RuntimeError::RuntimeUnavailable(format!("failed to read Kokoro tokenizer: {error}"))
        })?,
        512,
    )?;
    let encoded = tokenizer.encode_phonemes(&phonemes)?;
    let token_count = encoded.len().saturating_sub(2);
    let style = load_kokoro_voice_style(model_root, token_count)?;
    let padded = [vec![0_i64], encoded, vec![0_i64]].concat();
    let model = tract_onnx::onnx()
        .model_for_path(model_root.join("onnx/model_quantized.onnx"))
        .and_then(|model| model.into_optimized())
        .and_then(|model| model.into_runnable())
        .map_err(|error| {
            RuntimeError::RuntimeUnavailable(format!("Kokoro model load failed: {error}"))
        })?;
    let outputs = model
        .run(tvec![
            Tensor::from_shape(&[1, padded.len()], &padded)
                .map_err(|error| RuntimeError::RuntimeUnavailable(error.to_string()))?
                .into_tvalue(),
            Tensor::from_shape(&[1, 256], &style)
                .map_err(|error| RuntimeError::RuntimeUnavailable(error.to_string()))?
                .into_tvalue(),
            Tensor::from_shape(&[1], &[1.0_f32])
                .map_err(|error| RuntimeError::RuntimeUnavailable(error.to_string()))?
                .into_tvalue(),
        ])
        .map_err(|error| {
            RuntimeError::RuntimeUnavailable(format!("Kokoro inference failed: {error}"))
        })?;
    let pcm = outputs
        .first()
        .ok_or_else(|| RuntimeError::RuntimeUnavailable("Kokoro returned no audio".to_owned()))?
        .try_as_plain_ram()
        .map_err(|error| RuntimeError::RuntimeUnavailable(error.to_string()))?
        .as_slice::<f32>()
        .map_err(|error| RuntimeError::RuntimeUnavailable(error.to_string()))?;
    encode_wav_pcm_24khz(pcm)
}

#[cfg(not(feature = "kokoro-tract-runtime"))]
pub fn synthesize_kokoro(_model_root: &Path, _text: &str) -> Result<Vec<u8>, RuntimeError> {
    Err(RuntimeError::RuntimeUnavailable(
        "Kokoro inference runtime requires a maintained ONNX Runtime integration".to_owned(),
    ))
}

#[cfg(feature = "kokoro-tract-runtime")]
fn encode_wav_pcm_24khz(samples: &[f32]) -> Result<Vec<u8>, RuntimeError> {
    let mut wav = Vec::with_capacity(44 + samples.len() * 2);
    let data_len = (samples.len() * 2) as u32;
    let riff_len = 36 + data_len;
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&riff_len.to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&24_000_u32.to_le_bytes());
    wav.extend_from_slice(&48_000_u32.to_le_bytes());
    wav.extend_from_slice(&2_u16.to_le_bytes());
    wav.extend_from_slice(&16_u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    for sample in samples {
        let clamped = sample.clamp(-1.0, 1.0);
        let value = (clamped * i16::MAX as f32) as i16;
        wav.extend_from_slice(&value.to_le_bytes());
    }
    Ok(wav)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(not(feature = "kokoro-sherpa-runtime"))]
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

    #[cfg(not(feature = "kokoro-sherpa-runtime"))]
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
        assert!(matches!(
            synthesize_kokoro(root.path(), "hello").unwrap_err(),
            RuntimeError::RuntimeUnavailable(_)
        ));
    }

    #[test]
    fn serializes_runtime_capability_with_stable_field_names() {
        let capability = RuntimeCapability {
            engine: "kokoro",
            model_id: "kokoro-82m",
            installed: true,
            inference_ready: false,
            reason: Some("synthesis is not implemented".to_owned()),
        };
        assert_eq!(
            serde_json::to_string(&capability).unwrap(),
            r#"{"engine":"kokoro","model_id":"kokoro-82m","installed":true,"inference_ready":false,"reason":"synthesis is not implemented"}"#
        );
    }

    #[cfg(feature = "kokoro-tract-runtime")]
    #[test]
    fn selects_voice_style_row_by_token_count() {
        let root = tempdir().unwrap();
        let mut bytes = vec![0_u8; 2 * 256 * 4];
        bytes[256 * 4..256 * 4 + 4].copy_from_slice(&1.5_f32.to_le_bytes());
        fs::create_dir_all(root.path().join("voices")).unwrap();
        fs::write(root.path().join("voices/af.bin"), bytes).unwrap();
        let style = load_kokoro_voice_style(root.path(), 1).unwrap();
        assert_eq!(style[0], 1.5);
        assert_eq!(style.len(), 256);
    }

    #[cfg(feature = "kokoro-tract-runtime")]
    #[test]
    fn phonemizes_english_without_system_espeak_data() {
        let phonemes = phonemize_kokoro_english("Hello world").unwrap();
        assert!(!phonemes.is_empty());
        assert!(phonemes.contains('h'));
    }
}
