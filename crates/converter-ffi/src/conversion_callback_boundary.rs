use super::*;

/// Converts a book through the shared Rust worker and publishes each complete,
/// ffprobe-validated chapter in conversion order. `output_dir` must be the
/// directory named by `job_id`; event strings are valid only during callback.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_job_json(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
) -> *mut c_char {
    convert_job_json(
        handle,
        output_dir,
        job_id,
        chapter_start,
        chapter_end,
        progress_callback,
        callback,
        context,
        None,
        None,
        EmbeddedConversionOptionsV1::default(),
    )
}

/// Additive controlled entry point. Control must be valid during this call's
/// initial clone; cancellation and priority share state with the owned worker.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_controlled_job_json(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
    control: *const ConverterJobControl,
) -> *mut c_char {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        return fail("invalid null job control".to_owned());
    };
    let owned_control = control.control.clone();
    convert_job_json(
        handle,
        output_dir,
        job_id,
        chapter_start,
        chapter_end,
        progress_callback,
        callback,
        context,
        Some(owned_control),
        None,
        EmbeddedConversionOptionsV1 {
            audio_chunks: Some(control.audio_chunks.clone()),
            ..Default::default()
        },
    )
}

/// Controlled playback conversion with ordered per-chunk audio delivery.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_streaming_job_json(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    chapter_callback: ConverterChapterCompletedCallback,
    chunk_callback: ConverterAudioChunkCallback,
    context: *mut c_void,
    control: *const ConverterJobControl,
) -> *mut c_char {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        return fail("invalid null job control".to_owned());
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
            ..Default::default()
        },
    )
}

/// Streaming conversion with explicit per-job engine selection. The absent
/// or invalid engine keeps the established Edge default.
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
}

/// Whole-book conversion with an explicit per-job engine choice.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_job_options_json_v1(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    options_json: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    chapter_callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
) -> *mut c_char {
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
        None,
        None,
        options,
    )
}

/// Conversion with immutable per-job voice options and an independently cancellable control.
#[no_mangle]
pub unsafe extern "C" fn converter_session_convert_controlled_job_options_json_v1(
    handle: *const ConverterSession,
    output_dir: *const c_char,
    job_id: *const c_char,
    options_json: *const c_char,
    chapter_start: i32,
    chapter_end: i32,
    progress_callback: ConverterProgressCallback,
    chapter_callback: ConverterChapterCompletedCallback,
    context: *mut c_void,
    control: *const ConverterJobControl,
) -> *mut c_char {
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
        None,
        EmbeddedConversionOptionsV1 {
            audio_chunks: Some(control.audio_chunks.clone()),
            ..options
        },
    )
}
