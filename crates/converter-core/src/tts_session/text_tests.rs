use super::*;

fn plan(text: &str, limit: usize) -> Vec<SourceTextSegment> {
    plan_text_protecting(text, limit, limit, &[], &[]).unwrap()
}
fn coverage(text: &str, chunks: &[SourceTextSegment]) {
    assert_eq!(
        chunks
            .iter()
            .map(|chunk| chunk.source.as_str())
            .collect::<String>(),
        text
    );
    let mut byte = 0;
    let mut scalar = 0;
    for chunk in chunks {
        assert_eq!(chunk.byte_range.start, byte);
        assert_eq!(chunk.scalar_range.start, scalar);
        assert_eq!(&text[chunk.byte_range.clone()], chunk.source);
        byte = chunk.byte_range.end;
        scalar = chunk.scalar_range.end;
    }
    assert_eq!(byte, text.len());
    assert_eq!(scalar, text.chars().count());
}

#[test]
fn sentence_boundary_beats_a_later_space_and_retains_earlier_complete_sentence() {
    let text = "Uma frase completa. Outra frase ainda incompleta que continua por bastante tempo sem terminar";
    let chunks = plan(text, 48);
    assert_eq!(chunks[0].speech(), "Uma frase completa.");
    coverage(text, &chunks);
}

#[test]
fn paragraph_boundary_has_priority_without_changing_source_coordinates() {
    let text =
        "Água clara e fresca. Segue a narrativa com outra frase ainda longa sem um fim imediato";
    let end = "Água clara e fresca.".chars().count();
    let chunks = plan_text_protecting(text, 36, 36, &[], &[end]).unwrap();
    assert_eq!(chunks[0].speech(), "Água clara e fresca.");
    assert_eq!(chunks[0].scalar_range.end, end + 1);
    coverage(text, &chunks);
    for bad in [
        vec![0],
        vec![end, end],
        vec![end + 1, end],
        vec![text.chars().count() + 1],
    ] {
        assert!(plan_text_protecting(text, 36, 36, &[], &bad).is_err());
    }
}

#[test]
fn abbreviations_initials_decimals_ellipsis_quotes_and_dialogue_keep_terminal_context() {
    let text = "O Sr. Antônio e a Dra. Maria viram A. Silva. Custou R$ 12,50 e 3.14 dólares. — Sim! — Ela disse: “Espere...” Depois continuou a narrativa.";
    let chunks = plan(text, 55);
    assert_eq!(
        chunks[0].speech(),
        "O Sr. Antônio e a Dra. Maria viram A. Silva."
    );
    assert!(chunks.iter().all(|chunk| !chunk.speech().ends_with("Sr.")
        && !chunk.speech().ends_with("Dra.")
        && !chunk.speech().ends_with("A.")));
    coverage(text, &chunks);
}

#[test]
fn combining_accents_emoji_and_long_words_split_only_at_extended_graphemes() {
    for text in [
        "  água e\u{301} clara   👩🏽‍🚀! Outra frase.  ",
        "abcdefghijklmno",
        "汉字汉字汉字汉字汉字",
    ] {
        let chunks = plan(text, 8);
        coverage(text, &chunks);
        let boundaries = text
            .grapheme_indices(true)
            .map(|(offset, _)| offset)
            .chain(std::iter::once(text.len()))
            .collect::<Vec<_>>();
        for chunk in chunks {
            assert!(boundaries.contains(&chunk.byte_range.start));
            assert!(boundaries.contains(&chunk.byte_range.end));
            assert!(chunk.speech().chars().count() <= 8);
        }
    }
    assert!(plan_text_protecting("e\u{301}", 1, 1, &[], &[]).is_err());
    assert!(plan_text_protecting("👩🏽‍🚀", 2, 2, &[], &[]).is_err());
    assert_eq!(segment_text("abc", 1, 1).unwrap(), ["a", "b", "c"]);
}

#[test]
fn protected_terms_move_cut_before_match_or_remain_whole_at_start() {
    let text = "Início curto. Gandalf the Grey continuou pela estrada ao amanhecer.";
    let start = text.find("Gandalf").unwrap();
    let end = start + "Gandalf the Grey".len();
    let chunks = plan_text_protecting(text, 20, 20, &[(start, end)], &[]).unwrap();
    coverage(text, &chunks);
    assert!(chunks
        .iter()
        .all(|chunk| !(chunk.byte_range.end > start && chunk.byte_range.end < end)));
    assert!(chunks
        .iter()
        .any(|chunk| chunk.speech().contains("Gandalf the Grey")));
    assert!(plan_text_protecting(text, 20, 20, &[(end, start)], &[]).is_err());
    assert!(plan_text_protecting("á", 1, 1, &[(1, 2)], &[]).is_err());
}

#[test]
fn capacities_empty_input_and_many_boundaries_terminate_and_preserve_source() {
    assert!(segment_text("text", 0, 10).is_err());
    assert!(segment_text("text", 10, 0).is_err());
    assert!(plan("", 1).is_empty());
    assert!(plan(" \n\t ", 1).is_empty());
    for limit in [1, 2, 3, 17, 180, 800] {
        let text = "ábc palavra. Outra palavra?! ".repeat(40);
        let chunks = plan(&text, limit);
        coverage(&text, &chunks);
        assert!(chunks
            .iter()
            .all(|chunk| chunk.speech().chars().count() <= limit));
    }
}

#[test]
fn protected_scalar_edges_expand_to_graphemes_and_rebased_fallback_covers_source() {
    let text = "ae\u{301}foo xxx";
    let chunks = plan_text_protecting(text, 3, 3, &[(2, 5)], &[]).unwrap();
    coverage(text, &chunks);
    assert!(chunks
        .iter()
        .all(|chunk| !(chunk.byte_range.end > 1 && chunk.byte_range.end < 5)));
    let source = "  Primeiro trecho.  Segundo trecho. ";
    let parents = plan(source, 25);
    for parent in &parents {
        let mut children = plan(&parent.source, 9);
        for child in &mut children {
            child.rebase(parent);
        }
        assert_eq!(
            children.first().unwrap().scalar_range.start,
            parent.scalar_range.start
        );
        assert_eq!(
            children.last().unwrap().scalar_range.end,
            parent.scalar_range.end
        );
        assert_eq!(
            children.last().unwrap().byte_range.end,
            parent.byte_range.end
        );
    }
}
