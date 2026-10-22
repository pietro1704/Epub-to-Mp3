    #[test]
    fn empty_typed_manifest_metadata_preserves_legacy_shape_and_nondefault_round_trip() {
        let legacy = serde_json::json!({
            "jobId": "legacy", "title": "Book", "author": "Author", "chapters": [],
            "archive": "book.zip", "cover": null,
        });
        let mut manifest: OutputManifest = serde_json::from_value(legacy.clone()).unwrap();
        assert_eq!(serde_json::to_value(&manifest).unwrap(), legacy);
        let primary = crate::tts_preferences::TtsSelection {
            engine: "system".into(),
            model_id: None,
            voice: None,
        };
        manifest.tts_preferences = Some(crate::tts_preferences::TtsPreferences {
            policy_version: None,
            primary: primary.clone(),
            secondary: None,
            allow_online_fallback: false,
        });
        manifest.used_selections.push(primary);
        manifest.fallback_used = true;
        manifest
            .tts_policy_state
            .get_or_insert_with(Default::default)
            .primary_failed(false, true)
            .unwrap();
        let encoded = serde_json::to_value(&manifest).unwrap();
        assert_eq!(encoded["fallbackUsed"], true);
        assert_eq!(encoded["usedSelections"][0]["engine"], "system");
        assert_eq!(encoded["ttsPolicyState"]["consecutive_failures"], 1);
        assert_eq!(
            serde_json::from_value::<OutputManifest>(encoded).unwrap(),
            manifest
        );
    }


    #[test]
    fn android_piper_runtime_failure_does_not_require_unconsented_edge() {
        for status in [
            piper::PiperRuntimeStatus {
                runtime_loaded: false,
                model_available: false,
                abi_compatible: true,
                engine_ready: false,
            },
            piper::PiperRuntimeStatus {
                runtime_loaded: true,
                model_available: false,
                abi_compatible: false,
                engine_ready: false,
            },
        ] {
            let error = ensure_android_piper_runtime(status)
                .unwrap_err()
                .to_string();
            assert!(error.contains("unavailable or ABI-incompatible"), "{error}");
            assert!(!error.contains("Edge"), "{error}");
        }

        assert!(ensure_android_piper_runtime(piper::PiperRuntimeStatus {
            runtime_loaded: true,
            model_available: false,
            abi_compatible: true,
            engine_ready: false,
        })
        .is_ok());
    }

    #[test]
    fn performance_override_still_respects_configuration_and_platform_caps() {
        let fast = ExecutionOptions {
            max_performance: true,
            ..ExecutionOptions::default()
        };
        assert_eq!(
            ExecutionOptions::default().chapter_parallelism(true, 8, 8, 2),
            1
        );
        assert_eq!(fast.chapter_parallelism(true, 8, 8, 2), 2);
        assert_eq!(fast.chapter_parallelism(true, 1, 8, 2), 1);
        assert_eq!(fast.chapter_parallelism(true, 8, 1, 2), 1);
        assert_eq!(fast.chapter_parallelism(true, 8, 8, 1), 1);
    }

    #[test]
    fn positional_chapter_selector_from_ffi_matches_parsed_epub_position() {
        assert!(chapter_selection_matches("position:0", "1", 0));
        assert!(chapter_selection_matches("position:1", "2", 1));
        assert!(chapter_selection_matches("1", "1", 8));
        assert!(!chapter_selection_matches("position:0", "1", 1));
        assert!(!chapter_selection_matches("position:invalid", "1", 0));
    }

    #[test]
    fn typed_manifest_metadata_and_noninitial_policy_survive_serialization() {
        let legacy = serde_json::json!({"jobId":"typed-job","title":"Book","author":"Author",
            "chapters":[],"archive":"book.zip","cover":null});
        let mut manifest: OutputManifest = serde_json::from_value(legacy).unwrap();
        let preferences = crate::tts_preferences::TtsPreferences::default();
        manifest.tts_preferences = Some(preferences.clone());
        manifest.used_selections = vec![preferences.primary.clone()];
        manifest.fallback_used = true;
        manifest.tts_policy_state =
            Some(serde_json::from_value(serde_json::json!({"consecutive_failures":1})).unwrap());
        let value = serde_json::to_value(&manifest).unwrap();
        assert_eq!(value["fallbackUsed"], true);
        assert_eq!(value["ttsPolicyState"]["consecutive_failures"], 1);
        assert_eq!(
            value["ttsPreferences"],
            serde_json::to_value(preferences).unwrap()
        );
        assert_eq!(
            serde_json::from_value::<OutputManifest>(value).unwrap(),
            manifest
        );
    }

    #[test]
    fn legacy_output_manifest_keeps_unknown_source_count_without_changing_wire_shape() {
        let legacy = serde_json::json!({
            "jobId": "legacy-job", "title": "Book", "author": "Author",
            "chapters": [{"index": 1, "sourceIndex": 0, "title": "Chapter",
                          "filename": "chapter.mp3", "textChars": 40}],
            "archive": "book.zip", "cover": null
        });
        let manifest: OutputManifest = serde_json::from_value(legacy.clone()).unwrap();
        assert_eq!(manifest.source_chapters_total, None);
        assert_eq!(manifest.chapters.len(), 1);
        assert_eq!(serde_json::to_value(manifest).unwrap(), legacy);
    }

    #[test]
    fn explicit_source_count_round_trips_and_negative_count_is_rejected() {
        let mut value = serde_json::json!({
            "jobId": "selected-job", "title": "Book", "author": "Author",
            "chapters": [{"index": 1, "sourceIndex": 0, "title": "Chapter",
                          "filename": "chapter.mp3", "textChars": 40}],
            "sourceChaptersTotal": 2, "archive": "book.zip", "cover": null
        });
        let manifest: OutputManifest = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(manifest.source_chapters_total, Some(2));
        assert_eq!(manifest.chapters.len(), 1);
        assert_eq!(serde_json::to_value(manifest).unwrap(), value);
        value["sourceChaptersTotal"] = serde_json::json!(-1);
        assert!(serde_json::from_value::<OutputManifest>(value).is_err());
    }
