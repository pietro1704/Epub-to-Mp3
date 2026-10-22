    #[test]
    fn malformed_chapter_cache_is_rebuilt_from_source() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        fs::write(&path, b"{broken JSON").unwrap();
        assert_eq!(
            cached_chapter_text(&path, "Original chapter.").unwrap(),
            "Original chapter."
        );
        assert_eq!(
            cache::read_json::<String>(&path).unwrap(),
            "Original chapter."
        );
    }

    #[test]
    fn matching_chapter_cache_is_reused_without_rewriting() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        let bytes = b"  \"Original chapter.\"\n";
        fs::write(&path, bytes).unwrap();
        assert_eq!(
            cached_chapter_text(&path, "Original chapter.").unwrap(),
            "Original chapter."
        );
        assert_eq!(fs::read(path).unwrap(), bytes);
    }

    #[test]
    fn missing_chapter_cache_is_created_and_write_failures_are_reported() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        assert_eq!(
            cached_chapter_text(&path, "Original chapter.").unwrap(),
            "Original chapter."
        );
        assert_eq!(
            cache::read_json::<String>(&path).unwrap(),
            "Original chapter."
        );
        let blocked = root.path().join("blocked.json");
        fs::create_dir(&blocked).unwrap();
        assert!(cached_chapter_text(&blocked, "Original chapter.").is_err());
    }

    #[test]
    fn same_length_cache_corruption_is_rebuilt_from_source() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chapter.json");
        let expected = "The original chapter.";
        let corrupted = "x".repeat(expected.chars().count());
        cache::atomic_write_json(&path, &corrupted).unwrap();
        assert_eq!(cached_chapter_text(&path, expected).unwrap(), expected);
        assert_eq!(cache::read_json::<String>(&path).unwrap(), expected);
    }

    #[test]
    fn audio_request_key_changes_with_each_conversion_input() {
        let original = ("source", "1", "Text", "edge", Some("voice"), Some("en"));
        let key = |(source, chapter, text, engine, voice, language)| {
            chapter_audio_request_key(source, chapter, text, engine, voice, language).unwrap()
        };
        let expected = key(original);
        assert_eq!(key(original), expected);
        for changed in [
            ("other", "1", "Text", "edge", Some("voice"), Some("en")),
            ("source", "2", "Text", "edge", Some("voice"), Some("en")),
            ("source", "1", "Next", "edge", Some("voice"), Some("en")),
            ("source", "1", "Text", "piper", Some("voice"), Some("en")),
            ("source", "1", "Text", "edge", Some("other"), Some("en")),
            ("source", "1", "Text", "edge", Some("voice"), Some("fr")),
        ] {
            assert_ne!(key(changed), expected);
        }
    }
