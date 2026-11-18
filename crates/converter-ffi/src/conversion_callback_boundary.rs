use super::*;

/// Converts with captured per-job options, cancellation and optional streaming callbacks.
/// Omitted selection uses Piper with the installed system fallback; invalid options fail.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_streaming_job_options_json_v1(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    options_json: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    chapter_callback: ConverterChapterCompletedCallback,
    chunk_callback: ConverterAudioChunkCallback,
    context: *mut c_void,
    control: *const ConverterJobControl,
) -> *mut c_char {
    ffi_guard(
        "converter_session_convert_streaming_job_options_json_v1",
        std::ptr::null_mut(),
        || {
            clear_last_error();
            let Some(control) = control.as_ref() else {
                return fail("invalid null job control".to_owned());
            };
            let options_json = match c_string(options_json, "conversion options") {
                Ok(value) => value,
                Err(error) => return fail(error),
            };
            let options: EmbeddedConversionOptionsV1 = match serde_json::from_str(&options_json) {
                Ok(value) => value,
                Err(error) => return fail(format!("invalid conversion options JSON: {error}")),
            };
            convert_job_json(
                handle,
                output_dir,
                job_id,
                chapter_start,
                chapter_end,
                progress_callback,
                chapter_callback,
                context,
                Some(control.control.clone()),
                chunk_callback,
                EmbeddedConversionOptionsV1 {
                    audio_chunks: Some(control.audio_chunks.clone()),
                    ..options
                },
            )
        },
    )
}
