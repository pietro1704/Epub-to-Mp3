//! Optional Kokoro runtime backed by the official sherpa-onnx C API.
//!
//! This module is feature-gated because sherpa-onnx requires a native
//! ONNX Runtime archive for each distribution target.

use std::{ffi::CString, path::Path};

use crate::tts_runtime::RuntimeError;

pub fn synthesize_wav(model_root: &Path, text: &str) -> Result<Vec<u8>, RuntimeError> {
    let model_path = if model_root.join("model.int8.onnx").is_file() {
        model_root.join("model.int8.onnx")
    } else {
        model_root.join("model.onnx")
    };
    let model = CString::new(model_path.to_string_lossy().as_bytes())
        .map_err(|_| RuntimeError::RuntimeUnavailable("invalid model path".into()))?;
    let voices = CString::new(model_root.join("voices.bin").to_string_lossy().as_bytes())
        .map_err(|_| RuntimeError::RuntimeUnavailable("invalid voices path".into()))?;
    let tokens = CString::new(model_root.join("tokens.txt").to_string_lossy().as_bytes())
        .map_err(|_| RuntimeError::RuntimeUnavailable("invalid tokens path".into()))?;
    let data_dir = CString::new(
        model_root
            .join("espeak-ng-data")
            .to_string_lossy()
            .as_bytes(),
    )
    .map_err(|_| RuntimeError::RuntimeUnavailable("invalid data path".into()))?;
    let input = CString::new(text)
        .map_err(|_| RuntimeError::RuntimeUnavailable("text contains a NUL byte".into()))?;

    // SAFETY: all C strings remain alive for the duration of each call and the
    // returned audio is released by the matching sherpa-onnx destructor.
    unsafe {
        let mut config: sherpa_onnx_sys::OfflineTtsConfig = std::mem::zeroed();
        config.model.num_threads = 0;
        let provider = CString::new("cpu").unwrap();
        config.model.provider = provider.as_ptr();
        config.model.kokoro.model = model.as_ptr();
        config.model.kokoro.voices = voices.as_ptr();
        config.model.kokoro.tokens = tokens.as_ptr();
        config.model.kokoro.data_dir = data_dir.as_ptr();
        config.model.kokoro.length_scale = 1.0;
        config.max_num_sentences = 2;

        let tts = sherpa_onnx_sys::SherpaOnnxCreateOfflineTts(&config);
        if tts.is_null() {
            return Err(RuntimeError::RuntimeUnavailable(
                "sherpa-onnx failed to create Kokoro runtime".into(),
            ));
        }
        let generation = sherpa_onnx_sys::SherpaOnnxGenerationConfig {
            silence_scale: 0.0,
            speed: 1.0,
            sid: 0,
            reference_audio: std::ptr::null(),
            reference_audio_len: 0,
            reference_sample_rate: 0,
            reference_text: std::ptr::null(),
            num_steps: 0,
            extra: std::ptr::null(),
        };
        let audio = sherpa_onnx_sys::SherpaOnnxOfflineTtsGenerateWithConfig(
            tts,
            input.as_ptr(),
            &generation,
            None,
            std::ptr::null_mut(),
        );
        let result = if audio.is_null() {
            Err(RuntimeError::RuntimeUnavailable(
                "sherpa-onnx failed to synthesize Kokoro audio".into(),
            ))
        } else {
            let samples = std::slice::from_raw_parts((*audio).samples, (*audio).n as usize);
            Ok(wav_from_f32(samples, (*audio).sample_rate))
        };
        if !audio.is_null() {
            sherpa_onnx_sys::SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
        }
        sherpa_onnx_sys::SherpaOnnxDestroyOfflineTts(tts);
        result
    }
}

fn wav_from_f32(samples: &[f32], sample_rate: i32) -> Vec<u8> {
    let mut pcm = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        let value = (sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
        pcm.extend_from_slice(&value.to_le_bytes());
    }
    let data_len = pcm.len() as u32;
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&(sample_rate as u32).to_le_bytes());
    wav.extend_from_slice(&((sample_rate as u32) * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(&pcm);
    wav
}

#[cfg(test)]
mod tests {
    use super::wav_from_f32;

    #[test]
    fn encodes_mono_pcm_wave_header() {
        let wav = wav_from_f32(&[0.0, 1.0, -1.0], 24_000);
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(wav.len(), 50);
    }
}
