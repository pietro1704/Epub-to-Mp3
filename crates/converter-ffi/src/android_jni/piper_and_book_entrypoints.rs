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
