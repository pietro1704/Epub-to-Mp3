use ndarray::{Array1, Array2};
use ort::session::Session;
use ort::value::Tensor;

use crate::PiperError;
use crate::PiperResult;

pub const BOS: char = '^';
pub const EOS: char = '$';
pub const PAD: char = '_';

pub use crate::model_config::ModelConfig;

pub fn phonemes_to_ids(config: &ModelConfig, phonemes: &str) -> Vec<i64> {
    let map = &config.phoneme_id_map;
    let pad_id = *map.get(&PAD).and_then(|v| v.first()).unwrap_or(&0);
    let bos_id = *map.get(&BOS).and_then(|v| v.first()).unwrap_or(&0);
    let eos_id = *map.get(&EOS).and_then(|v| v.first()).unwrap_or(&0);

    let mut ids = Vec::with_capacity((phonemes.len() + 1) * 2);
    ids.push(bos_id);
    for ch in phonemes.chars() {
        if let Some(id) = map.get(&ch).and_then(|v| v.first()) {
            ids.push(*id);
            ids.push(pad_id);
        }
    }
    ids.push(eos_id);
    ids
}

pub fn infer(
    session: &mut Session,
    config: &ModelConfig,
    phonemes: &str,
    noise_scale: f32,
    length_scale: f32,
    noise_w: f32,
    speaker_id: i64,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> PiperResult<Vec<f32>> {
    let ids = phonemes_to_ids(config, phonemes);
    let input_len = ids.len();
    let input = Array2::<i64>::from_shape_vec((1, input_len), ids).unwrap();
    let input_lengths = Array1::<i64>::from_iter([input_len as i64]);
    let scales = Array1::<f32>::from_iter([noise_scale, length_scale, noise_w]);

    let input_t = Tensor::<i64>::from_array((
        [1, input_len],
        input.into_raw_vec_and_offset().0.into_boxed_slice(),
    ))
    .unwrap();
    let lengths_t = Tensor::<i64>::from_array((
        [1],
        input_lengths.into_raw_vec_and_offset().0.into_boxed_slice(),
    ))
    .unwrap();
    let scales_t =
        Tensor::<f32>::from_array(([3], scales.into_raw_vec_and_offset().0.into_boxed_slice()))
            .unwrap();

    let options = ort::session::run_options::RunOptions::new()
        .map_err(|error| PiperError::InferenceError(error.to_string()))?;
    // The monitor is joined on every path. Dropping the sender also releases it
    // if inference panics; no synthesis or cancellation thread is detached.
    let outputs = std::thread::scope(|scope| {
        let (finished, completion) = std::sync::mpsc::channel::<()>();
        let options = &options;
        let monitor = scope.spawn(move || loop {
            if cancelled() {
                return options.terminate();
            }
            match completion.recv_timeout(std::time::Duration::from_millis(10)) {
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                _ => return Ok(()),
            }
        });
        let result = if config.num_speakers > 1 {
            let sid = Array1::<i64>::from_iter([speaker_id]);
            let sid_t = Tensor::<i64>::from_array((
                [1],
                sid.into_raw_vec_and_offset().0.into_boxed_slice(),
            ))
            .unwrap();
            session.run_with_options(ort::inputs![input_t, lengths_t, scales_t, sid_t], options)
        } else {
            session.run_with_options(ort::inputs![input_t, lengths_t, scales_t], options)
        };
        drop(finished);
        monitor
            .join()
            .map_err(|_| PiperError::InferenceError("Cancellation monitor panicked".into()))?
            .map_err(|error| {
                PiperError::InferenceError(format!("Cannot interrupt inference: {error}"))
            })?;
        result.map_err(|error| PiperError::InferenceError(format!("Inference failed: {error}")))
    })?;

    let (_, audio) = outputs[0]
        .try_extract_tensor::<f32>()
        .map_err(|e| PiperError::InferenceError(format!("Failed to extract output: {}", e)))?;

    Ok(audio.to_vec())
}
