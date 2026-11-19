use super::*;

#[test]
fn preformatted_whitespace_before_inline_content_keeps_its_text_offsets() {
    let mut input = request("<pre>  \n<span>😀code</span>\n  </pre>");
    input.search_text = "code".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(chapter.text, "  \n😀code\n  ");
    assert_eq!(chapter.search_matches[0].start, 5);
    assert_eq!(chapter.search_matches[0].end, 9);
    assert!(joined(&chapter).contains("<pre>  \n<span>"));
    assert_eq!(chapter.pages[0].end, chapter.text.encode_utf16().count());
}

#[test]
fn astral_combining_and_cross_node_matches_share_one_axis() {
    let mut input = request("<p>Olá 😀 <em>ca</em>fé e\u{301}.</p>");
    input.search_text = "CAFÉ".into();
    input.audio_text = "😀 café".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(chapter.text, "Olá 😀 café e\u{301}.");
    assert_eq!(chapter.offset_unit, "utf16");
    assert_eq!(
        (
            chapter.search_matches[0].start,
            chapter.search_matches[0].end
        ),
        (7, 11)
    );
    let audio = chapter.audio_match.as_ref().unwrap();
    assert_eq!((audio.start, audio.end), (4, 11));
    let html = joined(&chapter);
    assert!(html
        .contains("<em><mark data-reader-search=\"0\" data-reader-audio=\"true\">ca</mark></em>"));
    assert!(html.contains("data-reader-audio=\"true\">fé</mark>"));
    assert_eq!(chapter.pages[0].end, chapter.text.encode_utf16().count());
    let mut input = request("<p>😀 e\u{301} e\u{301}</p>");
    input.search_text = "e\u{301}".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(
        chapter
            .search_matches
            .iter()
            .map(|m| (m.start, m.end))
            .collect::<Vec<_>>(),
        [(3, 5), (6, 8)]
    );
}

#[test]
fn matching_is_literal_nonoverlapping_and_cannot_split_case_expansion() {
    let mut input = request("<p>aaaa İ i\u{307} [x]. 😀😀</p>");
    input.search_text = "aa".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(
        chapter
            .search_matches
            .iter()
            .map(|m| (m.start, m.end))
            .collect::<Vec<_>>(),
        [(0, 2), (2, 4)]
    );
    let mut input = request("<p>İ i\u{307}</p>");
    input.search_text = "i".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(chapter.search_matches.len(), 1);
    assert_eq!(
        (
            chapter.search_matches[0].start,
            chapter.search_matches[0].end
        ),
        (2, 3)
    );
    let mut input = request("<p>İ</p>");
    input.search_text = "i\u{307}".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(
        (
            chapter.search_matches[0].start,
            chapter.search_matches[0].end
        ),
        (0, 1)
    );
    let mut input = request("<p>[x].* [X].*</p>");
    input.search_text = "[x].*".into();
    input.audio_text = "absent".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(chapter.search_matches.len(), 2);
    assert!(chapter.audio_match.is_none());
}

#[test]
fn long_blocks_remain_whole_and_cross_page_highlights_use_start_page() {
    let long = "x".repeat(2300);
    let mut input = request(&format!("<p>{long}ab</p><p>cd and rest</p>"));
    input.search_text = "ab\ncd".into();
    input.audio_text = "ab\ncd".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(chapter.pages.len(), 2);
    assert_eq!((chapter.pages[0].start, chapter.pages[0].end), (0, 2302));
    assert_eq!(chapter.pages[1].start, 2302);
    assert!(chapter.pages[0].html.contains(&long));
    assert!(chapter
        .pages
        .iter()
        .all(|page| page.html.contains("data-reader-search=\"0\"")));
    assert_eq!(chapter.search_matches[0].page_index, 0);
    assert_eq!(chapter.audio_match.unwrap().page_index, 0);
    assert_eq!(chapter.text, format!("{long}ab\ncd and rest"));
}

#[test]
fn typography_changes_block_grouping_without_changing_text() {
    let html = format!(
        "<p>{}</p><p>{}</p><p>{}</p>",
        "a".repeat(1000),
        "b".repeat(1000),
        "c".repeat(1000)
    );
    let standard = render(&html);
    assert_eq!(standard.pages.len(), 2);
    let mut input = request(&html);
    input.preferences = ReaderPreferences {
        font_scale: 1.4,
        width_rem: 34.0,
        line_height: 2.1,
    };
    let narrow = render_chapter(input).unwrap();
    assert_eq!(narrow.pages.len(), 3);
    assert_eq!(narrow.text, standard.text);
    let mut input = request(&html);
    input.preferences = ReaderPreferences {
        font_scale: 0.9,
        width_rem: 68.0,
        line_height: 1.45,
    };
    assert_eq!(render_chapter(input).unwrap().pages.len(), 1);
}

#[test]
fn wrapper_language_direction_and_anchor_identity_survive_pagination() {
    let html = format!("<html lang=\"pt-BR\"><body dir=\"rtl\" style=\"text-align: right\"><section id=\"whole\"><p id=\"first\">{}</p><p id=\"second\"><a name=\"alias\"></a>end</p></section></body></html>", "x".repeat(2300));
    let chapter = render(&html);
    assert_eq!(chapter.pages.len(), 2);
    for page in &chapter.pages {
        assert!(page.html.contains("lang=\"pt-BR\""));
        assert!(page.html.contains("dir=\"rtl\""));
        assert!(page.html.contains("reader-inline-0"));
        assert!(!page.html.contains("style="));
    }
    assert!(chapter.css.contains("text-align: right"));
    assert!(chapter.pages[0].html.contains("id=\"whole\""));
    assert!(!chapter.pages[1].html.contains("id=\"whole\""));
    let anchors = chapter
        .anchors
        .iter()
        .map(|a| (a.id.as_str(), a.page_index))
        .collect::<Vec<_>>();
    assert_eq!(
        anchors,
        [("whole", 0), ("first", 0), ("second", 1), ("alias", 1)]
    );
}

#[test]
fn inline_spaces_preformatted_text_and_repaired_tables_remain_readable() {
    let chapter =
        render("<b>one</b> <i>two</i><pre>  exact\n line  </pre><table><tr><td>A<td>B</table>");
    assert_eq!(chapter.text, "one two\n  exact\n line  \nA\nB");
    let html = joined(&chapter);
    assert!(html.contains("<b>one</b> <i>two</i>"));
    assert!(html.contains("<tbody><tr><td>A</td><td>B</td></tr></tbody>"));
}

#[test]
fn structural_separators_prevent_artificial_matches_without_extra_markup() {
    let html = "<p>😀ab</p><p>cd<br>ef <em>gh</em></p>";
    let mut input = request(html);
    input.search_text = "abcd".into();
    input.audio_text = "cdef".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(chapter.text, "😀ab\ncd\nef gh");
    assert!(chapter.search_matches.is_empty());
    assert!(chapter.audio_match.is_none());
    let mut input = request(html);
    input.search_text = "cd\nef".into();
    let chapter = render_chapter(input).unwrap();
    assert_eq!(
        (
            chapter.search_matches[0].start,
            chapter.search_matches[0].end
        ),
        (5, 10)
    );
    let output = joined(&chapter);
    assert!(output.contains("<p>😀ab</p>"));
    assert!(output.contains("cd</mark><br><mark data-reader-search=\"0\">ef</mark>"));
    assert!(!output.contains('\n'));
    assert_eq!(render("<p>pre<em>fix</em></p>").text, "prefix");
}
