//! Parsing and pre-conversion resolution of the range, cache, retry and audit flags.
use super::cli_arguments::parse_args;
use super::cli_chapter_ranges::{range_selection, ChapterRange, TO_CHAPTER, TO_END};
use super::conversion_retry::RetryRounds;
use converter_core::embedded::{EmbeddedBookMetadata, EmbeddedChapterMetadata};

fn parse(arguments: &[&str]) -> Result<super::CliOptions, String> {
    let arguments: Vec<String> = arguments.iter().map(|value| (*value).to_owned()).collect();
    parse_args(&arguments)
}

fn range(flag: &'static str, start: &str, end: Option<&str>) -> ChapterRange {
    ChapterRange {
        flag,
        start: start.into(),
        end: end.map(str::to_owned),
    }
}

#[test]
fn range_flags_keep_literal_bounds_and_exclude_each_other() {
    assert_eq!(
        parse(&["book.epub", TO_END, "2.1"]).unwrap().chapter_range,
        Some(range(TO_END, "2.1", None))
    );
    assert_eq!(
        parse(&["book.epub", TO_CHAPTER, " 2 .. 5.1 "])
            .unwrap()
            .chapter_range,
        Some(range(TO_CHAPTER, "2", Some("5.1")))
    );
    // The position selector keeps its colon; only `..` separates the bounds.
    assert_eq!(
        parse(&["book.epub", TO_CHAPTER, "position:1..position:3"])
            .unwrap()
            .chapter_range,
        Some(range(TO_CHAPTER, "position:1", Some("position:3")))
    );
    assert_eq!(parse(&["book.epub"]).unwrap().chapter_range, None);

    for arguments in [
        [TO_END, "2", TO_CHAPTER, "2..3"],
        [TO_CHAPTER, "2..3", TO_END, "2"],
    ] {
        let error = parse(&arguments).unwrap_err();
        assert!(error.contains("mutually exclusive"), "{error}");
        assert!(
            error.contains(TO_END) && error.contains(TO_CHAPTER),
            "{error}"
        );
    }
    assert!(parse(&[TO_END, "2", TO_END, "3"])
        .unwrap_err()
        .contains("only once"));
    for alias in ["2:5", "2,5"] {
        assert_eq!(
            parse(&["book.epub", TO_CHAPTER, alias])
                .unwrap()
                .chapter_range,
            Some(range(TO_CHAPTER, "2", Some("5")))
        );
    }
    for malformed in ["2-5", "2", "..3", "3..", " .. "] {
        let error = parse(&["book.epub", TO_CHAPTER, malformed]).unwrap_err();
        assert!(
            error.contains("requires an inclusive range A..B"),
            "{error}"
        );
    }
    assert!(parse(&["book.epub", TO_END, "  "])
        .unwrap_err()
        .contains("requires a chapter selector"));
    assert!(parse(&["book.epub", TO_END])
        .unwrap_err()
        .contains("requires a value"));
    assert!(parse(&["book.epub", TO_CHAPTER])
        .unwrap_err()
        .contains("requires a value"));
}

#[test]
fn cache_and_retry_flags_default_to_the_unretried_cached_conversion() {
    let defaults = parse(&["book.epub"]).unwrap();
    assert!(!defaults.force_reprocess && !defaults.verify_only && !defaults.fix);
    assert_eq!(
        RetryRounds::from_options(&defaults),
        RetryRounds {
            automatic: 0,
            manual: false
        }
    );
    let options = parse(&[
        "book.epub",
        "--force-reprocess",
        "--retry-failed",
        "3",
        "--retry-failed-manual",
    ])
    .unwrap();
    assert!(options.force_reprocess);
    assert_eq!(
        RetryRounds::from_options(&options),
        RetryRounds {
            automatic: 3,
            manual: true
        }
    );
    assert_eq!(
        parse(&["book.epub", "--retry-failed", "0"])
            .unwrap()
            .retry_failed_rounds,
        Some(0)
    );
    for invalid in ["-1", "many", "1.5", ""] {
        let error = parse(&["book.epub", "--retry-failed", invalid]).unwrap_err();
        assert!(
            error.contains("--retry-failed requires a non-negative number"),
            "{error}"
        );
    }
    assert!(parse(&["book.epub", "--retry-failed"])
        .unwrap_err()
        .contains("requires a value"));
}

#[test]
fn existing_output_modes_reject_conversion_options_by_name() {
    assert!(parse(&["book.epub", "--verify-only"]).unwrap().verify_only);
    assert!(parse(&["book.epub", "--fix"]).unwrap().fix);
    assert!(parse(&["book.epub", "--verify-only", "--fix"])
        .unwrap_err()
        .contains("mutually exclusive"));
    let snapshot = r#"{"primary":{"engine":"piper","model_id":"pt_BR-faber-medium"},"secondary":null,"allow_online_fallback":false}"#;
    for (extra, named) in [
        (&["--chapter", "1"][..], "--chapter"),
        (&["--section", "1"][..], "--section"),
        (&[TO_END, "1"][..], TO_END),
        (&[TO_CHAPTER, "1..2"][..], TO_CHAPTER),
        (&["--force-reprocess"][..], "--force-reprocess"),
        (&["--clean-cache"][..], "--clean-cache"),
        (&["--verify"][..], "--verify"),
        (&["--show-structure"][..], "--show-structure"),
        (&["--no-parallel"][..], "--no-parallel"),
        (&["--engine", "piper"][..], "--engine"),
        (&["--voice", "any"][..], "--voice"),
        (&["--no-online-fallback"][..], "--no-online-fallback"),
        (
            &["--tts-preferences-json", snapshot][..],
            "--tts-preferences-json",
        ),
    ] {
        for mode in ["--verify-only", "--fix"] {
            let error = parse(&[&["book.epub", mode][..], extra].concat()).unwrap_err();
            assert!(
                error.starts_with(&format!("{named} cannot be combined with {mode}")),
                "{error}"
            );
        }
    }
    // The cache-clearing command is a conversion-side action as well.
    assert!(parse(&["clear-cache", "book.epub", "--verify-only"])
        .unwrap_err()
        .starts_with("--clean-cache cannot be combined"));
    // A pure audit has nothing to retry; a fix reconverts, so rounds apply to it.
    for retry in [&["--retry-failed", "2"][..], &["--retry-failed-manual"][..]] {
        let error = parse(&[&["book.epub", "--verify-only"][..], retry].concat()).unwrap_err();
        assert!(
            error.starts_with(&format!("{} cannot be combined", retry[0])),
            "{error}"
        );
    }
    let fix = parse(&[
        "book.epub",
        "--fix",
        "--retry-failed",
        "2",
        "--retry-failed-manual",
    ])
    .unwrap();
    assert_eq!(
        RetryRounds::from_options(&fix),
        RetryRounds {
            automatic: 2,
            manual: true
        }
    );
}

fn book(chapters: &[(&str, &str)]) -> EmbeddedBookMetadata {
    EmbeddedBookMetadata {
        skipped_pages: 0,
        title: "Fixture".into(),
        author: String::new(),
        language: None,
        chapters: chapters
            .iter()
            .map(|(index, text)| EmbeddedChapterMetadata {
                index: (*index).into(),
                name: format!("Chapter {index}"),
                source_path: format!("{index}.xhtml"),
                text_chars: text.chars().count(),
                text: (*text).into(),
                level: 1,
                footnotes: Vec::new(),
            })
            .collect(),
        toc: Vec::new(),
    }
}

#[test]
fn ranges_resolve_to_explicit_positions_or_fail_with_the_flag_named() {
    let metadata = book(&[
        ("1", "one"),
        ("2", "two"),
        ("2.1", "two one"),
        ("3", " "),
        ("4", "four"),
    ]);
    let none: [String; 0] = [];
    assert_eq!(
        range_selection(&metadata, &range(TO_END, "2.1", None), &none).unwrap(),
        ["position:2", "position:3", "position:4"]
    );
    assert_eq!(
        range_selection(&metadata, &range(TO_CHAPTER, "1", Some("2.1")), &none).unwrap(),
        ["position:0", "position:1", "position:2"]
    );
    // --chapter and --section narrow the range instead of widening it.
    let selectors = ["2.1".to_owned(), "4".to_owned(), "position:0".to_owned()];
    assert_eq!(
        range_selection(&metadata, &range(TO_CHAPTER, "2", Some("3")), &selectors).unwrap(),
        ["position:2"]
    );
    let outside = ["4".to_owned()];
    let error =
        range_selection(&metadata, &range(TO_CHAPTER, "1", Some("2")), &outside).unwrap_err();
    assert!(
        error.starts_with(TO_CHAPTER) && error.contains("inside the range"),
        "{error}"
    );

    let unknown = range_selection(&metadata, &range(TO_END, "9.9", None), &none).unwrap_err();
    assert_eq!(
        unknown,
        format!("{TO_END}: chapter selector '9.9' matches no chapter")
    );
    let reversed =
        range_selection(&metadata, &range(TO_CHAPTER, "4", Some("2")), &none).unwrap_err();
    assert!(
        reversed.starts_with(TO_CHAPTER) && reversed.contains("at or after '4'"),
        "{reversed}"
    );
    let blank = range_selection(&metadata, &range(TO_CHAPTER, "3", Some("3")), &none).unwrap_err();
    assert!(blank.contains("no readable text"), "{blank}");
}

#[test]
fn range_narrowing_resolves_literal_indices_before_positional_aliases() {
    let metadata = book(&[("1", "one"), ("2", "two"), ("3", "three")]);
    let whole = range(TO_CHAPTER, "1", Some("3"));
    let select =
        |selector: &str| range_selection(&metadata, &whole, &[selector.to_owned()]).unwrap();
    // Bare 1 names the first chapter; only position:1 names the second.
    assert_eq!(select("1"), ["position:0"]);
    assert_eq!(select("2"), ["position:1"]);
    assert_eq!(select("position:1"), ["position:1"]);
    assert_eq!(select("position:0"), ["position:0"]);
    // Resolving before intersection prevents an out-of-range literal from
    // silently turning into an in-range positional alias.
    let outside = range_selection(
        &metadata,
        &range(TO_CHAPTER, "2", Some("3")),
        &["1".to_owned()],
    )
    .unwrap_err();
    assert!(outside.contains("inside the range"), "{outside}");
    let unnumbered = book(&[("cover", "one"), ("preface", "two"), ("story", "three")]);
    assert_eq!(
        range_selection(
            &unnumbered,
            &range(TO_CHAPTER, "cover", Some("story")),
            &["1".to_owned()],
        )
        .unwrap(),
        ["position:1"]
    );
    assert!(range_selection(&metadata, &whole, &["position:9".to_owned()]).is_err());
}
