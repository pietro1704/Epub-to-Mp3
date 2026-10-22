use super::*;

#[no_mangle]
pub extern "C" fn converter_job_control_create() -> *mut ConverterJobControl {
    clear_last_error();
    Box::into_raw(Box::new(ConverterJobControl {
        control: ConversionControl::new(),
        audio_chunks: Default::default(),
    }))
}

/// Enable bounded file-backed audio events before starting conversion. Keep the
/// handle alive until the worker has finished and all queued events are drained.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_enable_audio_chunks(
    control: *const ConverterJobControl,
) -> bool {
    let Some(control) = control.as_ref() else {
        return false;
    };
    let Ok(mut queue) = control.audio_chunks.lock() else {
        return false;
    };
    if queue.enabled {
        return false;
    }
    queue.enabled = true;
    true
}

/// Nonblocking poll. Returns an owned JSON string, or null when no event is ready.
/// Payload is {chapterIndex,chunkIndex,path}; an overflow returns {error} and
/// cancels conversion. Release each string with converter_string_free.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_take_audio_chunk_json(
    control: *const ConverterJobControl,
) -> *mut c_char {
    let Some(control) = control.as_ref() else {
        return ptr::null_mut();
    };
    let Ok(mut queue) = control.audio_chunks.try_lock() else {
        return ptr::null_mut();
    };
    let event = queue
        .error
        .take()
        .map(|error| json!({"error":error}))
        .or_else(|| queue.events.pop_front());
    event
        .and_then(|event| CString::new(event.to_string()).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

#[no_mangle]
pub unsafe extern "C" fn converter_job_control_free(control: *mut ConverterJobControl) {
    if !control.is_null() {
        drop(Box::from_raw(control));
    }
}

#[no_mangle]
pub unsafe extern "C" fn converter_job_control_cancel(control: *const ConverterJobControl) {
    if let Some(control) = control.as_ref() {
        control.control.cancel();
    }
}

/// Suspends subsequent chapter boundaries without interrupting the current
/// validated artifact. Cancellation wakes a suspended worker.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_set_paused(
    control: *const ConverterJobControl,
    paused: bool,
) {
    if let Some(control) = control.as_ref() {
        control.control.set_paused(paused);
    }
}

#[no_mangle]
pub unsafe extern "C" fn converter_job_control_set_playback_window(
    control: *const ConverterJobControl,
    current_chapter: usize,
    chapters_ahead: usize,
) {
    if let Some(control) = control.as_ref() {
        control
            .control
            .set_playback_window(current_chapter, chapters_ahead);
    }
}

/// Returns whether a source chapter still belongs to the active playback
/// window. Streaming adapters use this at chunk delivery so seeks can stop an
/// in-flight, now-distant chapter before its audio is persisted.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_chapter_is_in_playback_window(
    control: *const ConverterJobControl,
    chapter_index: usize,
) -> bool {
    control
        .as_ref()
        .is_some_and(|control| control.control.chapter_is_in_playback_window(chapter_index))
}

#[no_mangle]
pub unsafe extern "C" fn converter_job_control_prioritize(
    control: *const ConverterJobControl,
    chapter_index: usize,
) -> bool {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        fail::<()>("invalid null job control".to_owned());
        return false;
    };
    match control.control.prioritize(chapter_index) {
        Ok(()) => true,
        Err(error) => {
            fail::<()>(error.to_string());
            false
        }
    }
}

/// Selects a durable predecessor for a new job before its queue attaches.
/// The ID is copied; the caller may immediately release its UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn converter_job_control_set_recovery_job(
    control: *const ConverterJobControl,
    source_job_id: *const c_char,
) -> bool {
    clear_last_error();
    let Some(control) = control.as_ref() else {
        fail::<()>("invalid null job control".to_owned());
        return false;
    };
    let source_job_id = match c_string(source_job_id, "recovery job ID") {
        Ok(value) => value,
        Err(error) => {
            fail::<()>(error);
            return false;
        }
    };
    match control.control.set_recovery_job(&source_job_id) {
        Ok(()) => true,
        Err(error) => {
            fail::<()>(error.to_string());
            false
        }
    }
}
