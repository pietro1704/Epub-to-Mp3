use super::*;
use serde_json::{json, Value};

mod layout_tests;
mod resource_tests;
mod security_tests;

fn request(html: &str) -> ChapterRequest {
    serde_json::from_value(json!({"version": 1, "html": html})).unwrap()
}

fn render(html: &str) -> ReaderChapter {
    render_chapter(request(html)).unwrap()
}

fn joined(chapter: &ReaderChapter) -> String {
    chapter
        .pages
        .iter()
        .map(|page| page.html.as_str())
        .collect()
}

#[test]
fn shared_browser_goldens_use_the_same_text_and_utf16_ranges() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../ruby_app/rails_gateway/test/fixtures/reader_contract.json"
    )))
    .unwrap();
    for chapter in fixture["book"]["chapters"].as_array().unwrap() {
        let html = chapter["html"].as_str().unwrap();
        for (key, golden) in fixture["layouts"][html].as_object().unwrap() {
            let (search, audio) = key.split_once('|').unwrap();
            let mut input = request(html);
            input.css = chapter["css"].as_str().map(str::to_owned);
            input.search_text = search.into();
            input.audio_text = audio.into();
            let actual = serde_json::to_value(render_chapter(input).unwrap()).unwrap();
            for field in [
                "version",
                "offsetUnit",
                "text",
                "searchMatches",
                "audioMatch",
                "anchors",
            ] {
                assert_eq!(actual[field], golden[field], "{key}: {field}");
            }
            let actual_pages = actual["pages"].as_array().unwrap();
            let expected_pages = golden["pages"].as_array().unwrap();
            assert_eq!(actual_pages.len(), expected_pages.len(), "{key}");
            for (actual, expected) in actual_pages.iter().zip(expected_pages) {
                assert_eq!(actual["start"], expected["start"]);
                assert_eq!(actual["end"], expected["end"]);
            }
        }
    }
}

#[test]
fn plain_text_fallback_escapes_markup_and_empty_content_has_no_pages() {
    let input = serde_json::from_value(json!({
        "version": 1, "text": "<script>alert(1)</script> & \"words\"\nnext\n\nlast"
    }))
    .unwrap();
    let chapter = render_chapter(input).unwrap();
    let html = joined(&chapter);
    assert!(html.contains("&lt;script&gt;"));
    assert!(html.contains("<br>next</p><p>last</p>"));
    assert!(!html.contains("<script>"));
    for source in [
        "",
        "   ",
        "<p> </p>",
        "<div lang=\"en\"></div>",
        "<script>active</script>",
    ] {
        let chapter = render(source);
        assert!(chapter.pages.is_empty(), "{source}");
        assert!(chapter.text.is_empty());
    }
}

#[test]
fn version_schema_and_finite_geometry_fail_explicitly() {
    for source in [
        "{}",
        "[]",
        "null",
        "{",
        r#"{"version":2}"#,
        r#"{"version":1,"html":3}"#,
    ] {
        assert!(chapter_json(source).is_err(), "{source}");
    }
    for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let mut input = request("<p>text</p>");
        input.preferences.font_scale = value;
        assert!(render_chapter(input).is_err());
    }
    let json = chapter_json(r#"{"version":1,"text":"valid"}"#).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&json).unwrap()["text"],
        "valid"
    );
}

#[test]
fn request_limits_fail_before_unbounded_output() {
    let mut input = request("<p>ok</p>");
    input.search_text = "x".repeat(4097);
    assert!(matches!(
        render_chapter(input),
        Err(ReaderError::Limit {
            kind: "search bytes",
            ..
        })
    ));
    let mut input = request("<p>ok</p>");
    input.audio_text = "x".repeat(64 * 1024 + 1);
    assert!(render_chapter(input).is_err());
    assert!(chapter_json(&" ".repeat(MAX_CHAPTER_BYTES * 4 + 1)).is_err());
    assert!(render_chapter(request(&"x".repeat(MAX_CHAPTER_BYTES + 1))).is_err());
    let mut input = request("<p>ok</p>");
    input.css = Some(" ".repeat(MAX_CSS_BYTES + 1));
    assert!(render_chapter(input).is_err());
    let mut input = request(&format!("<p>{}</p>", "x".repeat(MAX_MATCHES + 1)));
    input.search_text = "x".into();
    assert!(matches!(
        render_chapter(input),
        Err(ReaderError::Limit {
            kind: "search matches",
            ..
        })
    ));
}

#[test]
fn escaping_does_not_reinterpret_or_reduce_the_plain_text_input_budget() {
    let text = "<".repeat(MAX_CHAPTER_BYTES / 2);
    let input = serde_json::from_value(json!({"version": 1, "text": text})).unwrap();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(chapter.text.len(), MAX_CHAPTER_BYTES / 2);
    assert_eq!(
        joined(&chapter).matches("&lt;").count(),
        MAX_CHAPTER_BYTES / 2
    );
    let input =
        serde_json::from_value(json!({"version": 1, "text": "\n".repeat(MAX_NODES)})).unwrap();
    assert!(render_chapter(input).is_err());
}
