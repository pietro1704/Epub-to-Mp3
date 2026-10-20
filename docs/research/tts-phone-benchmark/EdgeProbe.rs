use converter_core::adaptive::AdaptiveThroughputController;
use converter_core::tts::synthesize_with_reference_client;
use std::ffi::{c_char, CStr};
use std::sync::Arc;
use std::time::Duration;

/// Benchmark-only C entrypoint using the same Edge client as production.
#[no_mangle]
pub unsafe extern "C" fn benchmark_edge(
    text: *const c_char,
    output: *const c_char,
    error: *mut c_char,
    error_capacity: i32,
) -> i32 {
    let result = std::panic::catch_unwind(|| -> Result<(), String> {
        let text = unsafe { CStr::from_ptr(text) }.to_str().map_err(|e| e.to_string())?;
        let output = unsafe { CStr::from_ptr(output) }.to_str().map_err(|e| e.to_string())?;
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
        let audio = runtime.block_on(async {
            tokio::time::timeout(Duration::from_secs(45), synthesize_with_reference_client(
                text, "pt-BR-FranciscaNeural", Arc::new(AdaptiveThroughputController::default()), None,
            )).await.map_err(|_| "45 second synthesis deadline exceeded".to_owned())?
                .map_err(|e| e.to_string())
        })?;
        std::fs::write(output, audio).map_err(|e| e.to_string())
    });
    match result {
        Ok(Ok(())) => 0,
        failed => {
            let message = match failed { Ok(Err(message)) => message, _ => "Rust Edge probe panicked".to_owned() };
            if !error.is_null() && error_capacity > 0 {
                let count = message.len().min(error_capacity as usize - 1);
                unsafe { std::ptr::copy_nonoverlapping(message.as_ptr(), error.cast::<u8>(), count); *error.add(count) = 0; }
            }
            1
        }
    }
}
