use std::ffi::c_char;

mod ffi_boundary;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(all(feature = "onnxruntime", not(feature = "piper-inference")))]
use ort::{ep, session::Session};
#[cfg(feature = "piper-inference")]
use piper_rs::Piper;

static SESSION_IDENTITY: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
static INITIALIZED: AtomicBool = AtomicBool::new(false);

#[cfg(feature = "piper-inference")]
static RUNTIME: std::sync::OnceLock<std::sync::Mutex<Option<Piper>>> = std::sync::OnceLock::new();

#[cfg(feature = "piper-inference")]
pub fn set_espeak_data_directory(path: &Path) -> Result<(), String> {
    espeak_rs::set_espeak_data_directory(path).map_err(|error| error.to_string())
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
    ffi_boundary::guard(
        piper_runtime_status_t {
            runtime_loaded: 0,
            model_available: 0,
            abi_compatible: 0,
            engine_ready: 0,
        },
        || {
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
        },
    )
}

/// Reports that the embedded runtime ABI is available to platform loaders.
#[no_mangle]
pub extern "C" fn piper_runtime_register_core() -> i32 {
    ffi_boundary::guard(0, || {
        i32::from(cfg!(feature = "piper-inference") && cfg!(feature = "onnxruntime"))
    })
}

#[no_mangle]
pub extern "C" fn piper_runtime_init(
    model: *const c_char,
    config: *const c_char,
    error_buffer: *mut c_char,
    error_len: u32,
) -> i32 {
    let result = ffi_boundary::guard(Err("Piper runtime initialization panicked".into()), || {
        let model = unsafe { ffi_boundary::input(model, "model") }?;
        let config = unsafe { ffi_boundary::input(config, "config") }?;
        if !Path::new(model).is_file() {
            return Err("Piper model is missing".to_owned());
        }
        if !Path::new(config).is_file() {
            return Err("Piper voice config is missing".to_owned());
        }
        let identity = [model, config]
            .iter()
            .map(|path| {
                let metadata = fs::metadata(path).map_err(|e| e.to_string())?;
                Ok(format!(
                    "{}:{}:{:?}",
                    path,
                    metadata.len(),
                    metadata.modified().map_err(|e| e.to_string())?
                ))
            })
            .collect::<Result<Vec<_>, String>>()?
            .join("|");
        let mut selected = SESSION_IDENTITY
            .lock()
            .map_err(|_| "Piper session lock poisoned".to_owned())?;
        if INITIALIZED.load(Ordering::Acquire) && selected.as_deref() == Some(identity.as_str()) {
            return Ok(());
        }
        let config_data = fs::read_to_string(config)
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
        #[cfg(all(feature = "onnxruntime", not(feature = "piper-inference")))]
        {
            let _session = Session::builder()
                .map_err(|error| error.to_string())?
                .with_execution_providers([ep::CPU::default().build()])
                .map_err(|error| error.to_string())?
                .commit_from_file(model)
                .map_err(|error| error.to_string())?;
        }
        #[cfg(feature = "piper-inference")]
        {
            let piper = Piper::new(Path::new(model), Path::new(config))
                .map_err(|error| error.to_string())?;
            RUNTIME
                .get_or_init(|| std::sync::Mutex::new(None))
                .lock()
                .map_err(|_| "Piper runtime lock poisoned".to_owned())?
                .replace(piper);
        }
        *selected = Some(identity);
        Ok::<(), String>(())
    });
    match result {
        Ok(()) => {
            INITIALIZED.store(true, Ordering::Release);
            1
        }
        Err(message) => {
            error(error_buffer, error_len, &message);
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
    let result = ffi_boundary::guard(Err("Piper synthesis panicked".into()), || {
        if !INITIALIZED.load(Ordering::Acquire) {
            return Err("Piper runtime is not initialized".to_owned());
        }
        let text = unsafe { ffi_boundary::input(text, "text") }?;
        let output_path = unsafe { ffi_boundary::input(output, "output") }?;
        #[cfg(feature = "piper-inference")]
        {
            synthesize_cancellable(text, Path::new(output_path), &|| false)
        }
        #[cfg(not(feature = "piper-inference"))]
        {
            let _ = output_path;
            synthesize_cancellable(text, Path::new(""), &|| false)
        }
    });
    match result {
        Ok(()) => 1,
        Err(message) => {
            error(error_buffer, error_len, &message);
            0
        }
    }
}

/// Rust adapters carry request cancellation without changing the legacy C ABI.
pub fn synthesize_cancellable(
    text: &str,
    output: &Path,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Result<(), String> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        synthesize_cancellable_inner(text, output, cancelled)
    }))
    .unwrap_or_else(|_| Err("Piper synthesis panicked".into()))
}

fn synthesize_cancellable_inner(
    text: &str,
    output: &Path,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Result<(), String> {
    if cancelled() {
        return Err("Piper synthesis cancelled".into());
    }
    if !INITIALIZED.load(Ordering::Acquire) {
        return Err("Piper runtime is not initialized".into());
    }
    if text.trim().is_empty() {
        return Err("Piper synthesis text is empty".into());
    }
    #[cfg(feature = "piper-inference")]
    {
        let runtime = RUNTIME
            .get()
            .ok_or_else(|| "Piper inference runtime is not initialized".to_owned())?;
        let mut runtime = loop {
            if cancelled() {
                return Err("Piper synthesis cancelled".into());
            }
            match runtime.try_lock() {
                Ok(guard) => break guard,
                Err(std::sync::TryLockError::Poisoned(_)) => {
                    return Err("Piper runtime lock poisoned".into())
                }
                Err(std::sync::TryLockError::WouldBlock) => {
                    std::thread::sleep(std::time::Duration::from_millis(10))
                }
            }
        };
        let piper = runtime
            .as_mut()
            .ok_or_else(|| "Piper inference runtime is not initialized".to_owned())?;
        let (samples, sample_rate) = piper
            .create_cancellable(text, false, None, None, None, None, cancelled)
            .map_err(|error| error.to_string())?;
        if cancelled() {
            return Err("Piper synthesis cancelled".into());
        }
        return write_wav(output, &samples, sample_rate);
    }
    #[cfg(not(feature = "piper-inference"))]
    {
        let _ = output;
        Err("Piper phonemizer/inference pipeline is not linked".into())
    }
}

#[no_mangle]
pub extern "C" fn piper_runtime_shutdown() {
    ffi_boundary::guard((), || {
        INITIALIZED.store(false, Ordering::Release);
        if let Ok(mut identity) = SESSION_IDENTITY.lock() {
            identity.take();
        }
        #[cfg(feature = "piper-inference")]
        if let Some(runtime) = RUNTIME.get() {
            if let Ok(mut runtime) = runtime.lock() {
                runtime.take();
            }
        }
    })
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
        let models = std::env::var_os("EPUB2MP3_PIPER_TEST_MODEL_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| root.join("../../models/piper"));
        let model = [
            models.join("en_US-lessac-medium.onnx"),
            models.join("pt_BR-faber-medium.onnx"),
        ]
        .into_iter()
        .find(|path| path.is_file())
        .expect("CI must provide a vendored Piper model");
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
        let cancelled_output = output.with_extension("cancelled.wav");
        let checks = std::sync::atomic::AtomicUsize::new(0);
        let result = super::synthesize_cancellable(
            "An active inference must stop and release its model for the next request.",
            &cancelled_output,
            &|| checks.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= 4,
        );
        assert!(
            result.is_err(),
            "Cancelled inference unexpectedly succeeded"
        );
        assert!(checks.load(std::sync::atomic::Ordering::SeqCst) >= 5);
        assert!(!cancelled_output.exists());
        super::synthesize_cancellable("The next request still works.", &cancelled_output, &|| {
            false
        })
        .unwrap();
        assert!(std::fs::metadata(&cancelled_output).unwrap().len() > 44);
        std::fs::remove_file(cancelled_output).unwrap();
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
