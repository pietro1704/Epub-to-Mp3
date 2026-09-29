use std::ffi::{c_char, CStr};
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(feature = "onnxruntime")]
use ort::{ep, session::Session};
#[cfg(feature = "piper-inference")]
use piper_rs::Piper;

static INITIALIZED: AtomicBool = AtomicBool::new(false);

#[cfg(feature = "piper-inference")]
static RUNTIME: std::sync::OnceLock<std::sync::Mutex<Option<Piper>>> = std::sync::OnceLock::new();

#[cfg(feature = "piper-inference")]
static MODEL_PATH: std::sync::OnceLock<std::sync::Mutex<Option<String>>> =
    std::sync::OnceLock::new();

#[cfg(feature = "piper-inference")]
pub fn configured_model_path() -> Option<String> {
    MODEL_PATH
        .get()
        .and_then(|value| value.lock().ok()?.clone())
}

#[cfg(feature = "piper-inference")]
#[no_mangle]
pub extern "C" fn piper_runtime_set_model_path(path: &str) {
    MODEL_PATH
        .get_or_init(|| std::sync::Mutex::new(None))
        .lock()
        .expect("Piper model path lock poisoned")
        .replace(path.to_owned());
}

fn error(buffer: *mut c_char, length: u32, message: &str) {
    if buffer.is_null() || length == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let copy_len = bytes.len().min(length as usize - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer.cast::<u8>(), copy_len);
        *buffer.add(copy_len) = 0;
    }
}

#[repr(C)]
pub struct piper_runtime_status_t {
    pub runtime_loaded: u8,
    pub model_available: u8,
    pub abi_compatible: u8,
    pub engine_ready: u8,
}

#[no_mangle]
pub extern "C" fn piper_runtime_status() -> piper_runtime_status_t {
    let ready = INITIALIZED.load(Ordering::Acquire);
    piper_runtime_status_t {
        runtime_loaded: u8::from(
            cfg!(feature = "piper-inference") && cfg!(feature = "onnxruntime"),
        ),
        model_available: u8::from(ready),
        abi_compatible: 1,
        engine_ready: u8::from(
            ready && cfg!(feature = "piper-inference") && cfg!(feature = "onnxruntime"),
        ),
    }
}

/// Reports that the embedded runtime ABI is available to platform loaders.
#[no_mangle]
pub extern "C" fn piper_runtime_register_core() -> i32 {
    i32::from(cfg!(feature = "piper-inference") && cfg!(feature = "onnxruntime"))
}

#[no_mangle]
pub extern "C" fn piper_runtime_init(
    model: *const c_char,
    config: *const c_char,
    error_buffer: *mut c_char,
    error_len: u32,
) -> i32 {
    let result = std::panic::catch_unwind(|| {
        let model = unsafe { CStr::from_ptr(model) }.to_string_lossy();
        let config = unsafe { CStr::from_ptr(config) }.to_string_lossy();
        if !Path::new(model.as_ref()).is_file() {
            return Err("Piper model is missing".to_owned());
        }
        if !Path::new(config.as_ref()).is_file() {
            return Err("Piper voice config is missing".to_owned());
        }
        let config_data = fs::read_to_string(config.as_ref())
            .map_err(|error| format!("Piper voice config cannot be read: {error}"))?;
        let config_json: serde_json::Value = serde_json::from_str(&config_data)
            .map_err(|error| format!("Piper voice config is invalid JSON: {error}"))?;
        let sample_rate = config_json
            .pointer("/audio/sample_rate")
            .and_then(serde_json::Value::as_u64)
            .ok_or_else(|| "Piper voice config has no audio.sample_rate".to_owned())?;
        if sample_rate == 0 {
            return Err("Piper voice config has an invalid sample rate".to_owned());
        }
        #[cfg(feature = "onnxruntime")]
        {
            let _session = Session::builder()
                .map_err(|error| error.to_string())?
                .with_execution_providers([ep::CPU::default().build()])
                .map_err(|error| error.to_string())?
                .commit_from_file(model.as_ref())
                .map_err(|error| error.to_string())?;
        }
        #[cfg(feature = "piper-inference")]
        {
            let piper = Piper::new(Path::new(model.as_ref()), Path::new(config.as_ref()))
                .map_err(|error| error.to_string())?;
            RUNTIME
                .get_or_init(|| std::sync::Mutex::new(None))
                .lock()
                .map_err(|_| "Piper runtime lock poisoned".to_owned())?
                .replace(piper);
        }
        Ok::<(), String>(())
    });
    match result {
        Ok(Ok(())) => {
            INITIALIZED.store(true, Ordering::Release);
            1
        }
        Ok(Err(message)) => {
            error(error_buffer, error_len, &message);
            0
        }
        Err(_) => {
            error(
                error_buffer,
                error_len,
                "Piper runtime initialization panicked",
            );
            0
        }
    }
}

#[no_mangle]
pub extern "C" fn piper_synthesize(
    text: *const c_char,
    output: *const c_char,
    error_buffer: *mut c_char,
    error_len: u32,
) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if !INITIALIZED.load(Ordering::Acquire) {
            return Err("Piper runtime is not initialized".to_owned());
        }
        let text = unsafe { CStr::from_ptr(text) }.to_string_lossy();
        let output = unsafe { CStr::from_ptr(output) }.to_string_lossy();
        if text.trim().is_empty() {
            return Err("Piper synthesis text is empty".to_owned());
        }
        #[cfg(feature = "piper-inference")]
        {
            let runtime = RUNTIME
                .get()
                .ok_or_else(|| "Piper inference runtime is not initialized".to_owned())?;
            let mut runtime = runtime
                .lock()
                .map_err(|_| "Piper runtime lock poisoned".to_owned())?;
            let piper = runtime
                .as_mut()
                .ok_or_else(|| "Piper inference runtime is not initialized".to_owned())?;
            let (samples, sample_rate) = piper
                .create(text.as_ref(), false, None, None, None, None)
                .map_err(|error| error.to_string())?;
            write_wav(Path::new(output.as_ref()), &samples, sample_rate)?;
            return Ok(());
        }
        #[cfg(not(feature = "piper-inference"))]
        Err("Piper phonemizer/inference pipeline is not linked".to_owned())
    });
    match result {
        Ok(Ok(())) => 1,
        Ok(Err(message)) => {
            error(error_buffer, error_len, &message);
            0
        }
        Err(_) => {
            error(error_buffer, error_len, "Piper synthesis panicked");
            0
        }
    }
}

#[no_mangle]
pub extern "C" fn piper_runtime_shutdown() {
    INITIALIZED.store(false, Ordering::Release);
    #[cfg(feature = "piper-inference")]
    if let Some(runtime) = RUNTIME.get() {
        if let Ok(mut runtime) = runtime.lock() {
            runtime.take();
        }
    }
}

#[cfg(feature = "piper-inference")]
fn write_wav(path: &Path, samples: &[f32], sample_rate: u32) -> Result<(), String> {
    if samples.is_empty() || sample_rate == 0 {
        return Err("Piper returned empty audio".to_owned());
    }
    let pcm: Vec<i16> = samples
        .iter()
        .map(|sample| (sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16)
        .collect();
    let data_len = (pcm.len() * 2) as u32;
    let mut bytes = Vec::with_capacity(44 + data_len as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&sample_rate.to_le_bytes());
    bytes.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_len.to_le_bytes());
    for sample in pcm {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    fs::write(path, bytes).map_err(|error| format!("Cannot write Piper WAV: {error}"))
}

#[cfg(test)]
mod tests {
    use super::piper_synthesize;
    use std::ffi::CString;
    use std::path::PathBuf;

    #[test]
    fn failed_synthesis_does_not_create_partial_output() {
        let output = std::env::temp_dir().join(format!(
            "piper-runtime-no-partial-output-{}-{}.wav",
            std::process::id(),
            unique_suffix()
        ));
        let text = CString::new("test").unwrap();
        let output_c = CString::new(output.to_string_lossy().as_bytes()).unwrap();
        let mut error = [0_i8; 256];

        let result = piper_synthesize(
            text.as_ptr(),
            output_c.as_ptr(),
            error.as_mut_ptr(),
            error.len() as u32,
        );

        assert_eq!(result, 0);
        assert!(!PathBuf::from(&output).exists());
    }

    #[cfg(feature = "heavy-runtime-tests")]
    #[test]
    fn piper_inference_generates_valid_wav_from_vendored_model() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let model = root
            .join("../../models/piper/pt_BR-faber-medium.onnx")
            .canonicalize()
            .unwrap();
        let config = PathBuf::from(format!("{}.json", model.display()));
        let output = std::env::temp_dir().join(format!(
            "piper-runtime-smoke-{}-{}.wav",
            std::process::id(),
            unique_suffix()
        ));
        let model_c = CString::new(model.to_string_lossy().as_bytes()).unwrap();
        let config_c = CString::new(config.to_string_lossy().as_bytes()).unwrap();
        let text = CString::new("Embedded Piper smoke test.").unwrap();
        let output_c = CString::new(output.to_string_lossy().as_bytes()).unwrap();
        let mut error = [0_i8; 1024];

        let init_result = super::piper_runtime_init(
            model_c.as_ptr(),
            config_c.as_ptr(),
            error.as_mut_ptr(),
            error.len() as u32,
        );
        assert_eq!(init_result, 1, "runtime init failed: {}", c_error(&error));
        let synthesis_result = super::piper_synthesize(
            text.as_ptr(),
            output_c.as_ptr(),
            error.as_mut_ptr(),
            error.len() as u32,
        );
        assert_eq!(synthesis_result, 1, "synthesis failed: {}", c_error(&error));
        let wav = std::fs::read(&output).unwrap();
        assert!(wav.len() > 44);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        super::piper_runtime_shutdown();
        let _ = std::fs::remove_file(output);
    }

    fn unique_suffix() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    }

    #[cfg(feature = "heavy-runtime-tests")]
    fn c_error(error: &[i8]) -> String {
        let bytes: Vec<u8> = error.iter().map(|value| *value as u8).collect();
        String::from_utf8_lossy(&bytes)
            .trim_end_matches('\0')
            .to_owned()
    }
}
