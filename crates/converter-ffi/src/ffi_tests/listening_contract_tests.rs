#[test]
fn versioned_listening_control_rejects_bad_identity_timing_and_cancelled_updates() {
    unsafe {
        let control = converter_job_control_create();
        let send_position = |text: &str| {
            let json = CString::new(text).unwrap();
            converter_job_control_set_listening_position_json_v2(control, json.as_ptr())
        };
        assert!(!converter_job_control_set_listening_position_json_v2(
            ptr::null(),
            ptr::null()
        ));
        assert!(send_position(
            r#"{"version":2,"chapter_index":3,"text_offset":7}"#
        ));
        let generation = (*control).control.listening_plan().unwrap().generation;
        assert!(!send_position(
            r#"{"version":3,"chapter_index":3,"text_offset":0}"#
        ));
        assert_eq!(
            (*control)
                .control
                .listening_plan()
                .unwrap()
                .position
                .text_offset,
            7
        );
        assert!(send_position(
            r#"{"version":2,"chapter_index":3,"text_offset":8}"#
        ));
        assert!(!(*control).control.generation_is_current(Some(generation)));
        assert!(!converter_job_control_observe_generation_v2(
            control, generation, 8.0, 480
        ));
        assert!(converter_job_control_observe_generation_v2(
            control,
            generation + 1,
            8.0,
            480
        ));
        assert!(!converter_job_control_observe_generation_v2(
            control,
            generation + 1,
            f64::NAN,
            480
        ));
        let feedback = CString::new(r#"{"version":2,"generation":1,"chapter_index":3,"remaining_audio_seconds":2,"playback_rate":2}"#).unwrap();
        assert!(converter_job_control_playback_feedback_json_v2(
            control,
            feedback.as_ptr()
        ));
        assert!(converter_job_control_chapter_is_in_playback_window(
            control, 4
        ));
        let old = CString::new(
            r#"{"version":2,"chapter_index":2,"remaining_audio_seconds":0,"playback_rate":1}"#,
        )
        .unwrap();
        assert!(!converter_job_control_playback_feedback_json_v2(
            control,
            old.as_ptr()
        ));
        converter_job_control_cancel(control);
        assert!(!send_position(
            r#"{"version":2,"chapter_index":0,"text_offset":0}"#
        ));
        assert!(!converter_job_control_playback_feedback_json_v2(
            control,
            feedback.as_ptr()
        ));
        converter_job_control_free(control);
    }
}

#[test]
fn cancelled_chunk_queue_discards_audio_but_reports_overflow_once() {
    unsafe {
        let control = converter_job_control_create();
        let event = json!({"chapterIndex":0,"chunkIndex":0,"path":"retired.mp3"});
        (*control)
            .audio_chunks
            .lock()
            .unwrap()
            .events
            .push_back(event.clone());
        let first = converter_job_control_take_audio_chunk_json(control);
        assert!(!first.is_null());
        converter_string_free(first);
        (*control)
            .audio_chunks
            .lock()
            .unwrap()
            .events
            .push_back(event);
        (*control).audio_chunks.lock().unwrap().error = Some("Audio chunk queue overflow".into());
        converter_job_control_cancel(control);
        let error = converter_job_control_take_audio_chunk_json(control);
        assert!(!error.is_null());
        assert!(std::ffi::CStr::from_ptr(error)
            .to_str()
            .unwrap()
            .contains("overflow"));
        converter_string_free(error);
        assert!(converter_job_control_take_audio_chunk_json(control).is_null());
        assert!((*control).audio_chunks.lock().unwrap().events.is_empty());
        converter_job_control_free(control);
    }
}

#[test]
fn manual_chunks_are_retired_when_a_versioned_listening_position_is_installed() {
    unsafe {
        let control = converter_job_control_create();
        let manual = json!({"version":2,"generation":null,"chapterIndex":0,"chunkIndex":0,"path":"manual.mp3"});
        (*control)
            .audio_chunks
            .lock()
            .unwrap()
            .events
            .push_back(manual.clone());
        let first = converter_job_control_take_audio_chunk_json(control);
        assert!(!first.is_null());
        converter_string_free(first);
        (*control)
            .audio_chunks
            .lock()
            .unwrap()
            .events
            .push_back(manual);
        let position = CString::new(r#"{"version":2,"chapter_index":0,"text_offset":1}"#).unwrap();
        assert!(converter_job_control_set_listening_position_json_v2(
            control,
            position.as_ptr()
        ));
        assert!(converter_job_control_take_audio_chunk_json(control).is_null());
        converter_job_control_free(control);
    }
}
