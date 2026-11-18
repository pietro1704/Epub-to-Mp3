use super::*;

#[test]
fn html5_repair_drops_active_content_and_attributes_before_serializing() {
    let html = r#"<h1 onclick="attack()">Readable &amp; safe</h1>
      <p><b>Bold<i>both</b>italic</i><unknown>kept</unknown></p>
      <script>hiddenScript</script><style>hiddenStyle</style>
      <iframe srcdoc="<script>attack()</script>">hiddenFrame</iframe>
      <svg><foreignObject><p>hiddenForeign</p></foreignObject></svg>
      <math><mtext>hiddenMath</mtext></math><template>hiddenTemplate</template>
      <form>hiddenForm<input autofocus></form><object>hiddenObject</object>
      <img src="https://tracker.invalid/pixel" alt="Image alternative" onerror="attack()">
      <p data-reader-search="90" data-reader-audio="true">ordinary</p>"#;
    let chapter = render(html);
    let result = joined(&chapter);
    assert!(chapter.text.contains("Readable & safe"));
    assert!(chapter.text.contains("kept"));
    assert!(chapter.text.contains("Image alternative"));
    for forbidden in [
        "hidden",
        "onclick",
        "onerror",
        "srcdoc",
        "tracker.invalid",
        "<svg",
        "<math",
        "<iframe",
        "<script",
        "<input",
        "<object",
        "data-reader-search",
        "data-reader-audio",
    ] {
        assert!(!result.contains(forbidden), "{forbidden}: {result}");
    }
}

#[test]
fn styles_are_classes_and_neither_markup_nor_css_can_fetch_remote_content() {
    let mut input = request(
        r#"<p style="text-align: center; color: rgb(20, 30, 40); background: url(https://tracker.invalid); position: fixed; display: none" class="prose">preserved</p>"#,
    );
    input.css = Some(
        r#"
        @import "https://tracker.invalid/style";
        p { color: red; background-image: url(https://tracker.invalid/img); }
        .prose { font-weight: bold; text-align: justify; }
        .unsafe { color: var(--secret); font-family: evil\28; }
        .comments { color: r/*split*/ed; padding: 1em; }
        .hidden { display: none; opacity: 0; height: 0; overflow: hidden; }
        .escape\64 { color: green; }
    "#
        .into(),
    );
    let chapter = render_chapter(input).unwrap();
    assert_eq!(chapter.text, "preserved");
    assert!(!joined(&chapter).contains("style="));
    assert!(joined(&chapter).contains("reader-inline-0"));
    assert!(chapter.css.contains("text-align: center"));
    assert!(chapter.css.contains("color: rgb(20, 30, 40)"));
    assert!(chapter.css.contains("font-weight: bold"));
    assert!(chapter.css.contains("color: red"));
    for forbidden in [
        "tracker", "url", "var(", "@", "\\", "position", "display", "opacity", "overflow", "height",
    ] {
        assert!(
            !chapter.css.contains(forbidden),
            "{forbidden}: {}",
            chapter.css
        );
    }
}

#[test]
fn explicit_links_allow_only_supported_protocols_and_escape_attributes() {
    let chapter = render(
        r#"<p>
      <a href=" HTTPS://example.org/?x=1&amp;y=2 ">web</a>
      <a href="mailto:reader@example.org">mail</a>
      <a href="javascript:alert(1)">js</a><a href="java&#10;script:alert(1)">encoded</a>
      <a href="//tracker.invalid/">protocol relative</a><a href="file:///private/data">file</a>
      <a href="data:text/html,evil">data</a><a href="https:///invalid">empty host</a>
      <a href="https://example.org/\bad">backslash</a>
      <a title="&quot; onmouseover=&quot;attack()">escaped</a>
      <a data-reader-chapter="1.01" data-reader-fragment="safe">internal</a>
      <a data-reader-chapter="1.evil" data-reader-fragment="bad">invalid</a>
    </p>"#,
    );
    let html = joined(&chapter);
    assert_eq!(html.matches("target=\"_blank\"").count(), 2);
    assert_eq!(html.matches("rel=\"noopener noreferrer\"").count(), 2);
    assert!(html.contains("href=\"HTTPS://example.org/?x=1&amp;y=2\""));
    assert!(html.contains("title=\"&quot; onmouseover=&quot;attack()\""));
    assert!(html.contains("data-reader-chapter=\"1.01\""));
    assert!(!html.contains("data-reader-chapter=\"1.evil\""));
    for forbidden in [
        "javascript:",
        "file:",
        "data:text",
        "href=\"//",
        "href=\"https:///",
        "href=\"https://example.org/\\",
    ] {
        assert!(!html.contains(forbidden));
    }
}

#[test]
fn nesting_nodes_and_css_rule_limits_fail_closed() {
    let deep = format!(
        "{}text{}",
        "<div>".repeat(MAX_DEPTH + 2),
        "</div>".repeat(MAX_DEPTH + 2)
    );
    assert!(matches!(
        render_chapter(request(&deep)),
        Err(ReaderError::Limit {
            kind: "markup depth",
            ..
        })
    ));
    let many = "<br>".repeat(MAX_NODES);
    assert!(matches!(
        render_chapter(request(&many)),
        Err(ReaderError::Limit {
            kind: "markup tokens",
            ..
        })
    ));
    let mut input = request("<p>text</p>");
    input.css = Some("p {color: red}".repeat(2049));
    assert!(matches!(
        render_chapter(input),
        Err(ReaderError::Limit {
            kind: "CSS rules",
            ..
        })
    ));
}

#[test]
fn local_routes_reject_encoded_traversal_and_preserve_fragment_identity() {
    assert_eq!(
        resources::resolve_local("OPS/a.xhtml", "../Text/a%20b.xhtml#caf%C3%A9"),
        Some(("Text/a b.xhtml".into(), "café".into()))
    );
    assert_eq!(
        resources::resolve_local("a.xhtml", "b.xhtml#target"),
        Some(("b.xhtml".into(), "target".into()))
    );
    assert_eq!(
        resources::resolve_local("OPS/a.xhtml", "#target"),
        Some(("OPS/a.xhtml".into(), "target".into()))
    );
    for href in [
        "../../outside",
        "%2e%2e/%2e%2e/outside",
        "%2fprivate/file",
        "https%3a//remote",
        "file:///secret",
        "//host/path",
        "a%5cb.xhtml",
        "a.xhtml?query",
        "a.xhtml#%00",
    ] {
        assert!(
            resources::resolve_local("OPS/a.xhtml", href).is_none(),
            "{href}"
        );
    }
}

#[test]
fn root_css_selectors_target_only_generated_root_wrappers() {
    let mut input = request("<html class=\"book\"><body class=\"prose\"><p class=\"reader-root-body reader-root-html content\">text</p></body></html>");
    input.css = Some("html.book > body.prose { color: red; } .body, #html { color: blue; }".into());
    let chapter = render_chapter(input).unwrap();
    assert!(chapter
        .css
        .contains(".reader-root-html.book > .reader-root-body.prose"));
    assert!(chapter.css.contains(".body, #html"));
    assert!(joined(&chapter).contains("<p class=\"content\">text</p>"));
    assert_eq!(joined(&chapter).matches("reader-root-body").count(), 1);
    assert_eq!(joined(&chapter).matches("reader-root-html").count(), 1);
}
