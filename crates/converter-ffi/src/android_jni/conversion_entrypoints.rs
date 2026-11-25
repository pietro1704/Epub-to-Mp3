#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvert(
    env: JNIEnv<'_>,
    activity: JObject<'_>,
    path: JString<'_>,
    output: JString<'_>,
    chapter_start: jint,
    chapter_end: jint,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvert",
        std::ptr::null_mut(),
        || {
            convert_android(
                env,
                activity,
                path,
                output,
                chapter_start,
                chapter_end,
                false,
                -1,
                None,
            )
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvertWithOptions(
    mut env: JNIEnv<'_>,
    activity: JObject<'_>,
    path: JString<'_>,
    output: JString<'_>,
    chapter_start: jint,
    chapter_end: jint,
    options_json: JString<'_>,
    streaming: jboolean,
    text_offset: jint,
) -> jstring {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvertWithOptions",
        std::ptr::null_mut(),
        || {
            let options = match read_string(&mut env, options_json).and_then(|value| {
                serde_json::from_str::<EmbeddedConversionOptionsV1>(&value)
                    .map_err(|e| e.to_string())
            }) {
                Ok(options) => options,
                Err(error) => {
                    fail::<()>(format!("Invalid Android conversion options: {error}"));
                    return std::ptr::null_mut();
                }
            };
            convert_android(
                env,
                activity,
                path,
                output,
                chapter_start,
                chapter_end,
                streaming != 0,
                i64::from(text_offset),
                Some(options),
            )
        },
    )
}

fn convert_android(
    mut env: JNIEnv<'_>,
    activity: JObject<'_>,
    path: JString<'_>,
    output: JString<'_>,
    chapter_start: jint,
    chapter_end: jint,
    streaming: bool,
    text_offset: i64,
    options: Option<EmbeddedConversionOptionsV1>,
) -> jstring {
    eprintln!("converter-ffi: nativeConvert entered");
    #[cfg(feature = "piper-runtime")]
    piper_runtime_register_embedded();
    let path = match read_string(&mut env, path) {
        Ok(path) => path,
        Err(_) => return std::ptr::null_mut(),
    };
    let output = match read_string(&mut env, output) {
        Ok(output) => output,
        Err(_) => return std::ptr::null_mut(),
    };
    let request_id = output.clone();
    let control = android_controls()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .entry(request_id.clone())
        .or_default()
        .clone();
    struct RemoveControl(String);
    impl Drop for RemoveControl {
        fn drop(&mut self) {
            android_controls()
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .remove(&self.0);
        }
    }
    let _remove_control = RemoveControl(request_id.clone());
    let input_path = path.clone();
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
    // Own the session while Java callbacks and conversion can unwind.
    let mut session = unsafe { Box::from_raw(handle) };
    let platform = match env.get_java_vm().and_then(|vm| {
        env.new_global_ref(&activity)
            .map(|activity| AndroidPlatformSpeech {
                vm,
                activity,
                input_path,
            })
    }) {
        Ok(platform) => platform,
        Err(error) => {
            fail::<()>(format!("Android speech adapter unavailable: {error}"));
            return std::ptr::null_mut();
        }
    };
    session.platform_tts = Some(Arc::new(platform));
    // Rust owns the start: a mid-chapter listen begins at this source offset.
    if let Err(error) = control.start_listening_at(chapter_start.max(0) as usize, text_offset) {
        fail::<()>(format!("Rust rejected the requested source text range: {error}"));
        return std::ptr::null_mut();
    }
    let job = converter_core::embedded::fresh_embedded_job_id();
    let output = match CString::new(Path::new(&output).join(&job).to_string_lossy().as_bytes()) {
        Ok(output) => output,
        Err(_) => {
            return std::ptr::null_mut();
        }
    };
    let job = match CString::new(job) {
        Ok(job) => job,
        Err(_) => return fail("Android job ID contains an interior NUL byte".into()),
    };
    let chunk_context = if streaming {
        match env.get_java_vm().and_then(|vm| {
            env.new_global_ref(&activity)
                .map(|activity| AndroidAudioChunks {
                    vm,
                    activity,
                    request_id: request_id.clone(),
                    root: Path::new(&request_id).join("chunks"),
                    control: control.clone(),
                    delivered: std::sync::atomic::AtomicUsize::new(0),
                })
        }) {
            Ok(context) => Some(context),
            Err(error) => {
                fail::<()>(format!("Android audio chunk bridge unavailable: {error}"));
                return std::ptr::null_mut();
            }
        }
    } else {
        None
    };
    let control = ConverterJobControl {
        control,
        audio_chunks: Default::default(),
    };
    let result = unsafe {
        convert_job_json(
            &mut *session,
            output.as_ptr(),
            job.as_ptr(),
            chapter_start,
            chapter_end,
            None,
            None,
            chunk_context
                .as_ref()
                .map_or(std::ptr::null_mut(), |context| {
                    (context as *const AndroidAudioChunks).cast_mut().cast()
                }),
            Some(control.control.clone()),
            if streaming {
                Some(android_audio_chunk)
            } else {
                None
            },
            options.unwrap_or_default(),
        )
    };
    eprintln!(
        "converter-ffi: conversion returned result={}",
        !result.is_null()
    );
    if result.is_null() {
        return std::ptr::null_mut();
    }
    let manifest = unsafe { CString::from_raw(result) }
        .to_string_lossy()
        .into_owned();
    if let Some(context) = &chunk_context {
        if context.delivered.load(std::sync::atomic::Ordering::Acquire) == 0 {
            let cached = serde_json::from_str::<serde_json::Value>(&manifest)
                .ok()
                .and_then(|value| {
                    value
                        .get("audioPath")
                        .and_then(|path| path.as_str())
                        .map(str::to_owned)
                });
            if let Some(path) = cached {
                let delivered = std::fs::read(&path).ok().is_some_and(|audio| {
                    context.dispatch(chapter_start.max(0) as usize, 0, &audio)
                });
                if !delivered {
                    fail::<()>("Android cached audio delivery was cancelled".into());
                    return std::ptr::null_mut();
                }
            }
        }
    }
    env.new_string(manifest)
        .map_or(std::ptr::null_mut(), |value| value.into_raw())
}
