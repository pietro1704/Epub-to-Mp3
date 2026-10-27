// eSpeak translate.h clause values; same mapping as rhasspy/piper-phonemize.
const SENTENCE: i32 = 0x0008_0000;
const CLAUSE: i32 = 0x0004_0000;

pub(super) fn append_terminator(output: &mut String, terminator: i32) -> bool {
    let punctuation = match terminator & 0x000f_ffff {
        value if value == (40 | SENTENCE) => ".",
        value if value == (40 | 0x2000 | SENTENCE) => "?",
        value if value == (45 | 0x3000 | SENTENCE) => "!",
        value if value == (20 | 0x1000 | CLAUSE) => ", ",
        value if value == (30 | CLAUSE) => ": ",
        value if value == (30 | 0x1000 | CLAUSE) => "; ",
        _ => "",
    };
    output.push_str(punctuation);
    terminator & SENTENCE != 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_clause_metadata_does_not_hide_punctuation() {
        let mut output = "ipa".to_owned();
        assert!(append_terminator(&mut output, 40 | SENTENCE | 0x0040_0000));
        assert_eq!(output, "ipa.");
    }

    #[test]
    fn eof_and_paragraph_close_sentences_without_fabricating_punctuation() {
        for terminator in [40 | SENTENCE | 0x0001_0000, 70 | SENTENCE] {
            let mut output = "ipa".to_owned();
            assert!(append_terminator(&mut output, terminator));
            assert_eq!(output, "ipa");
        }
    }

    #[test]
    fn voice_change_is_neither_punctuation_nor_sentence_end() {
        let mut output = "ipa".to_owned();
        assert!(!append_terminator(&mut output, 0x0002_0000));
        assert_eq!(output, "ipa");
    }
}
