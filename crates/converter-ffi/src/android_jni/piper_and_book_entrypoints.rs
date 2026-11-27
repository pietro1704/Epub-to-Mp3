#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesizeWithOptions(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    text: JString<'_>,
    output: JString<'_>,
    options_json: JString<'_>,
) -> jboolean {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesizeWithOptions",
        0,
        || {
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
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeParse(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeParse",
        std::ptr::null_mut(),
        || {
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
            let session = unsafe { Box::from_raw(handle) };
            let metadata = unsafe { converter_session_metadata_json(&*session) };
            if metadata.is_null() {
                std::ptr::null_mut()
            } else {
                let value = unsafe { CString::from_raw(metadata) }
                    .to_string_lossy()
                    .into_owned();
                env.new_string(value)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw())
            }
        },
    )
}

/// Library-shelf metadata JSON for the Flutter Android library, or null with
/// the error available through `nativeLastError`.
#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeLibraryMetadata(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeLibraryMetadata",
        std::ptr::null_mut(),
        || {
            let metadata = read_string(&mut env, path).and_then(|path| {
                super::book_metadata_boundary::library_metadata_json(Path::new(&path))
            });
            match metadata {
                Ok(value) => env
                    .new_string(value)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw()),
                Err(error) => fail(error),
            }
        },
    )
}

/// Reads or updates the chapter name overrides file; a null `index` only reads and a null or
/// blank `name` resets. Null with the error available through `nativeLastError`.
#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeChapterNames(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
    index: JString<'_>,
    name: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeChapterNames",
        std::ptr::null_mut(),
        || {
            let mut optional = |value: JString<'_>| -> Result<Option<String>, String> {
                if value.as_raw().is_null() {
                    Ok(None)
                } else {
                    read_string(&mut env, value).map(Some)
                }
            };
            let result = (|| {
                let path = optional(path)?.ok_or("path is required")?;
                let index = optional(index)?;
                let name = optional(name)?;
                super::chapter_names_boundary::chapter_names_update_json(
                    Path::new(&path),
                    index.as_deref(),
                    name.as_deref(),
                )
            })();
            match result {
                Ok(value) => env
                    .new_string(value)
                    .map_or(std::ptr::null_mut(), |value| value.into_raw()),
                Err(error) => fail(error),
            }
        },
    )
}

/// Filename cover contract JSON (`label`, `backgroundRgb`) for a book file name.
#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeFilenameCover(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    file_name: JString<'_>,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeFilenameCover",
        std::ptr::null_mut(),
        || match read_string(&mut env, file_name) {
            Ok(name) => env
                .new_string(super::chapter_names_boundary::filename_cover_json(&name))
                .map_or(std::ptr::null_mut(), |value| value.into_raw()),
            Err(error) => fail(error),
        },
    )
}
