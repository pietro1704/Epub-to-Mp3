#[test]
fn model_install_operation_exposes_plan_progress_and_cancellation() {
    let root = tempfile::tempdir().unwrap();
    let model = CString::new("pt_BR-faber-medium").unwrap();
    let root_path = CString::new(root.path().to_str().unwrap()).unwrap();
    unsafe {
        let operation = converter_tts_model_install_operation_create(
            model.as_ptr(),
            root_path.as_ptr(),
            u64::MAX,
        );
        assert!(!operation.is_null());
        let plan_json = converter_tts_model_install_operation_plan_json(operation);
        let plan: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(plan_json).to_str().unwrap()).unwrap();
        converter_string_free(plan_json);
        assert_eq!(plan["version"], 1);
        assert_eq!(plan["model_id"], "pt_BR-faber-medium");
        assert_eq!(plan["ready"], true);
        assert_eq!(plan["artifacts"].as_array().unwrap().len(), 2);
        assert!(converter_tts_model_install_operation_record_progress(
            operation, 0, 1024
        ));
        let event_json = converter_tts_model_install_operation_event_json(operation);
        let event: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(event_json).to_str().unwrap()).unwrap();
        converter_string_free(event_json);
        assert_eq!(event["stage"], "downloading");
        assert_eq!(event["bytes_completed"], 1024);
        converter_tts_model_install_operation_cancel(operation);
        let cancelled_json = converter_tts_model_install_operation_event_json(operation);
        let cancelled: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(cancelled_json).to_str().unwrap()).unwrap();
        converter_string_free(cancelled_json);
        assert_eq!(cancelled["stage"], "cancelled");
        converter_tts_model_install_operation_free(operation);
    }
}

#[test]
fn model_install_operation_rejects_duplicate_canonical_identity_until_release() {
    let root = tempfile::tempdir().unwrap();
    let model = CString::new("pt_BR-faber-medium").unwrap();
    let direct = CString::new(root.path().join("models").to_str().unwrap()).unwrap();
    let alias = CString::new(root.path().join("./models").to_str().unwrap()).unwrap();
    unsafe {
        let first = converter_tts_model_install_operation_create(
            model.as_ptr(),
            direct.as_ptr(),
            u64::MAX,
        );
        assert!(!first.is_null());
        let duplicate = converter_tts_model_install_operation_create(
            model.as_ptr(),
            alias.as_ptr(),
            u64::MAX,
        );
        assert!(duplicate.is_null());
        let error = converter_last_error();
        assert!(CStr::from_ptr(error)
            .to_str()
            .unwrap()
            .contains("duplicate model installation request"));
        converter_string_free(error);
        converter_tts_model_install_operation_free(first);
        let replacement = converter_tts_model_install_operation_create(
            model.as_ptr(),
            alias.as_ptr(),
            u64::MAX,
        );
        assert!(!replacement.is_null());
        converter_tts_model_install_operation_cancel(replacement);
        converter_tts_model_install_operation_free(replacement);
    }
}

#[test]
fn model_install_operation_recovers_only_a_persisted_attempt_identity() {
    let root = tempfile::tempdir().unwrap();
    let model = CString::new("pt_BR-faber-medium").unwrap();
    let root_path = CString::new(root.path().to_str().unwrap()).unwrap();
    unsafe {
        let missing = converter_tts_model_install_operation_recover(
            model.as_ptr(),
            root_path.as_ptr(),
            u64::MAX,
        );
        assert!(missing.is_null());
        assert!(converter_last_error().is_null());

        let first = converter_tts_model_install_operation_create(
            model.as_ptr(),
            root_path.as_ptr(),
            u64::MAX,
        );
        assert!(!first.is_null());
        let first_plan_json = converter_tts_model_install_operation_plan_json(first);
        let first_plan: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(first_plan_json).to_str().unwrap()).unwrap();
        converter_string_free(first_plan_json);
        converter_tts_model_install_operation_free(first);

        let recovered = converter_tts_model_install_operation_recover(
            model.as_ptr(),
            root_path.as_ptr(),
            u64::MAX,
        );
        assert!(!recovered.is_null());
        let recovered_plan_json = converter_tts_model_install_operation_plan_json(recovered);
        let recovered_plan: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(recovered_plan_json).to_str().unwrap()).unwrap();
        converter_string_free(recovered_plan_json);
        assert_eq!(recovered_plan["operation_id"], first_plan["operation_id"]);
        converter_tts_model_install_operation_cancel(recovered);
        converter_tts_model_install_operation_free(recovered);

        let cancelled = converter_tts_model_install_operation_recover(
            model.as_ptr(),
            root_path.as_ptr(),
            u64::MAX,
        );
        assert!(cancelled.is_null());
    }
}
