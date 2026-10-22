#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperStatus(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    #[cfg(feature = "piper-runtime")]
    piper_runtime_register_embedded();
    let status = {
        #[cfg(feature = "piper-runtime")]
        {
            let status = piper_runtime::piper_runtime_status();
            PiperStatus {
                runtime_loaded: status.runtime_loaded != 0,
                model_available: status.model_available != 0,
                abi_compatible: status.abi_compatible != 0,
                engine_ready: status.engine_ready != 0,
            }
        }
        #[cfg(not(feature = "piper-runtime"))]
        {
            unsafe { piper_runtime_status() }
        }
    };
    let value = serde_json::json!({
        "runtimeLoaded": status.runtime_loaded,
        "modelAvailable": status.model_available,
        "abiCompatible": status.abi_compatible,
        "engineReady": status.engine_ready,
    })
    .to_string();
    env.new_string(value)
        .map_or(std::ptr::null_mut(), |value| value.into_raw())
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesizeWithOptions(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    text: JString<'_>,
    output: JString<'_>,
    options_json: JString<'_>,
) -> jboolean {
    let result = (|| -> Result<(), String> {
        let text = read_string(&mut env, text)?;
        let output = read_string(&mut env, output)?;
        let json = read_string(&mut env, options_json)?;
        let mut options: EmbeddedConversionOptionsV1 =
            serde_json::from_str(&json).map_err(|e| e.to_string())?;
        if let Some(preferences) = &options.tts_preferences {
            preferences.validate(options.language.as_deref())?;
            if preferences.primary.engine != "piper" {
                return Err("Piper sample requires a Piper primary".into());
            }
            options.model_id = preferences.primary.model_id.clone();
        }
        let (model, config) = resolve_piper_model_paths(&options)?;
        #[cfg(feature = "piper-runtime")]
        {
            if let Some(directory) = options.espeak_data_directory.as_deref() {
                configure_piper_data_directory(Path::new(directory))?;
            }
            piper_runtime_register_embedded();
        }
        let config = converter_core::piper::PiperConfig::new(model, config);
        converter_core::piper::synthesize(
            &config,
            &text,
            Path::new(&output),
            &converter_core::piper::CancellationToken::default(),
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    })();
    match result {
        Ok(()) => 1,
        Err(error) => fail::<jboolean>(error),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesize(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    text: JString<'_>,
    output: JString<'_>,
) -> jboolean {
    let text = match read_string(&mut env, text) {
        Ok(value) => value,
        Err(error) => return fail::<jboolean>(error),
    };
    let output = match read_string(&mut env, output) {
        Ok(value) => value,
        Err(error) => return fail::<jboolean>(error),
    };
    let text = std::ffi::CString::new(text).unwrap();
    let output = std::ffi::CString::new(output).unwrap();
    let model = std::ffi::CString::new("/data/user/0/com.pietrocode.epubtomp3.flutter_app/app_flutter/tts-models/en_US-lessac-low.onnx/model.bin").unwrap();
    let config = std::ffi::CString::new("/data/user/0/com.pietrocode.epubtomp3.flutter_app/app_flutter/tts-models/en_US-lessac-low.onnx/model.json").unwrap();
    #[cfg(feature = "piper-runtime")]
    {
        let mut error = vec![0_u8; 2048];
        let initialized = piper_runtime::piper_runtime_init(
            model.as_ptr(),
            config.as_ptr(),
            error.as_mut_ptr(),
            error.len() as u32,
        );
        if initialized == 0 {
            let message = unsafe { std::ffi::CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            fail::<jboolean>(message);
            return 0;
        }
        let synthesized = piper_runtime::piper_synthesize(
            text.as_ptr(),
            output.as_ptr(),
            error.as_mut_ptr(),
            error.len() as u32,
        );
        if synthesized == 0 {
            let message = unsafe { std::ffi::CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            fail::<jboolean>(message);
            return 0;
        }
        return 1;
    }
    #[cfg(not(feature = "piper-runtime"))]
    unsafe {
        if piper_runtime_init(model.as_ptr(), config.as_ptr()) {
            if piper_synthesize(text.as_ptr(), output.as_ptr()) {
                1
            } else {
                0
            }
        } else {
            0
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeParse(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
) -> jstring {
    #[cfg(feature = "piper-runtime")]
    piper_runtime_register_embedded();
    let path = match read_string(&mut env, path) {
        Ok(path) => path,
        Err(error) => {
            return env
                .new_string(error)
                .map_or(std::ptr::null_mut(), |value| value.into_raw())
        }
    };
    let path = match CString::new(path) {
        Ok(path) => path,
        Err(_) => return std::ptr::null_mut(),
    };
    let handle = unsafe { converter_session_open(path.as_ptr()) };
    eprintln!("converter-ffi: open returned");
    if handle.is_null() {
        eprintln!("converter-ffi: open failed");
        return std::ptr::null_mut();
    }
    let metadata = unsafe { converter_session_metadata_json(handle) };
    let result = if metadata.is_null() {
        std::ptr::null_mut()
    } else {
        let value = unsafe { CStr::from_ptr(metadata) }
            .to_string_lossy()
            .into_owned();
        unsafe { converter_string_free(metadata) };
        env.new_string(value)
            .map_or(std::ptr::null_mut(), |value| value.into_raw())
    };
    unsafe { converter_session_free(handle as *mut ConverterSession) };
    result
}
