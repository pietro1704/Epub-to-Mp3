use super::*;

#[cfg(not(feature = "piper-runtime"))]
#[no_mangle]
pub unsafe extern "C" fn piper_runtime_status() -> PiperRuntimeStatusC {
    let status = piper::piper_runtime_status();
    PiperStatus {
        runtime_loaded: status.runtime_loaded,
        model_available: status.model_available,
        abi_compatible: status.abi_compatible,
        engine_ready: status.engine_ready,
    }
}

#[cfg(not(feature = "piper-runtime"))]
#[no_mangle]
pub unsafe extern "C" fn piper_runtime_init(model: *const c_char, config: *const c_char) -> bool {
    clear_last_error();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let model = c_string(model, "Piper model")?;
        let config = c_string(config, "Piper config")?;
        piper::piper_runtime_init(Path::new(&model), Path::new(&config))
            .map_err(|error| error.to_string())
    }));
    match result {
        Ok(Ok(())) => true,
        Ok(Err(error)) => {
            fail::<()>(error);
            false
        }
        Err(_) => {
            fail::<()>("Piper runtime initialization panicked".into());
            false
        }
    }
}

#[cfg(not(feature = "piper-runtime"))]
#[no_mangle]
pub unsafe extern "C" fn piper_synthesize(text: *const c_char, output: *const c_char) -> bool {
    clear_last_error();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let text = c_string(text, "Piper text")?;
        let output = c_string(output, "Piper output")?;
        piper::piper_synthesize(&text, Path::new(&output))
            .map(|_| ())
            .map_err(|error| error.to_string())
    }));
    match result {
        Ok(Ok(())) => true,
        Ok(Err(error)) => {
            fail::<()>(error);
            false
        }
        Err(_) => {
            fail::<()>("Piper synthesis panicked".into());
            false
        }
    }
}

#[cfg(not(feature = "piper-runtime"))]
#[no_mangle]
pub extern "C" fn piper_runtime_shutdown() {
    piper::piper_runtime_shutdown();
}

/// Registers the platform runtime through a conservative status-only bridge.
#[no_mangle]
pub extern "C" fn piper_runtime_register_unavailable() {
    piper::register_runtime(Arc::new(UnavailablePiperRuntime));
}
struct UnavailablePiperRuntime;
impl piper::PiperRuntime for UnavailablePiperRuntime {
    fn status(&self) -> piper::PiperRuntimeStatus {
        piper::PiperRuntimeStatus {
            runtime_loaded: false,
            model_available: false,
            abi_compatible: false,
            engine_ready: false,
        }
    }
    fn init(&self, _: &Path, _: &Path) -> Result<(), piper::PiperError> {
        Err(piper::PiperError::RuntimeUnavailable(
            "Native Piper implementation is not linked".into(),
        ))
    }
    fn synthesize(
        &self,
        _: &str,
        _: &Path,
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), piper::PiperError> {
        self.init(Path::new(""), Path::new(""))
    }
    fn shutdown(&self) {}
}

#[cfg(feature = "piper-runtime")]
#[no_mangle]
pub extern "C" fn piper_runtime_register_embedded() {
    piper::register_runtime(Arc::new(EmbeddedPiperRuntime));
}

/// Configure the native phonemizer for Rust hosts using the same embedded provider.
#[cfg(feature = "piper-runtime")]
pub fn configure_piper_data_directory(path: &Path) -> Result<(), String> {
    piper_runtime::set_espeak_data_directory(path)
}

#[cfg(feature = "piper-runtime")]
pub(super) struct EmbeddedPiperRuntime;

#[cfg(all(test, feature = "piper-runtime"))]
#[test]
fn embedded_piper_honors_catalog_model_path_contract() {
    use converter_core::piper::PiperRuntime;
    assert!(EmbeddedPiperRuntime.supports_explicit_model_paths());
}

#[cfg(feature = "piper-runtime")]
impl converter_core::piper::PiperRuntime for EmbeddedPiperRuntime {
    fn supports_explicit_model_paths(&self) -> bool {
        true
    }
    fn status(&self) -> converter_core::piper::PiperRuntimeStatus {
        let native = piper_runtime::piper_runtime_status();
        converter_core::piper::PiperRuntimeStatus {
            runtime_loaded: native.runtime_loaded != 0,
            model_available: native.model_available != 0,
            abi_compatible: native.abi_compatible != 0,
            engine_ready: native.engine_ready != 0,
        }
    }

    fn init(&self, model: &Path, config: &Path) -> Result<(), converter_core::piper::PiperError> {
        let model = CString::new(model.to_string_lossy().as_bytes())
            .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
        let config = CString::new(config.to_string_lossy().as_bytes())
            .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
        let mut error = vec![0 as std::ffi::c_char; 2048];
        if piper_runtime::piper_runtime_init(
            model.as_ptr(),
            config.as_ptr(),
            error.as_mut_ptr(),
            error.len() as u32,
        ) == 0
        {
            return Err(converter_core::piper::PiperError::Synthesis(c_error(
                unsafe { std::slice::from_raw_parts(error.as_ptr().cast::<u8>(), error.len()) },
            )));
        }
        Ok(())
    }

    fn synthesize(
        &self,
        text: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), converter_core::piper::PiperError> {
        CString::new(text)
            .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
        CString::new(output.to_string_lossy().as_bytes())
            .map_err(|error| converter_core::piper::PiperError::Synthesis(error.to_string()))?;
        piper_runtime::synthesize_cancellable(text, output, cancelled)
            .map_err(converter_core::piper::PiperError::Synthesis)
    }

    fn shutdown(&self) {
        piper_runtime::piper_runtime_shutdown();
    }
}

#[cfg(feature = "piper-runtime")]
fn c_error(error: &[u8]) -> String {
    String::from_utf8_lossy(error)
        .trim_end_matches('\0')
        .to_owned()
}
