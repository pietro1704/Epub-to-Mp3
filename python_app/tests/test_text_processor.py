# -*- coding: utf-8 -*-
"""
Unit tests for TextProcessor class
"""

import unittest

from src.ebook_reader import TextProcessor


class TestTextProcessor(unittest.TestCase):
    """Test cases for TextProcessor class"""

    def test_html_to_plain_text_empty_input(self):
        """Test html_to_plain_text with empty input"""
        self.assertEqual(TextProcessor.html_to_plain_text(""), "")
        self.assertEqual(TextProcessor.html_to_plain_text(None), "")

    def test_html_to_plain_text_simple_html(self):
        """Test html_to_plain_text with simple HTML"""
        html = "<p>Hello world</p>"
        expected = "Hello world"
        result = TextProcessor.html_to_plain_text(html)
        self.assertEqual(result, expected)

    def test_html_to_plain_text_complex_html(self):
        """Test html_to_plain_text with complex HTML"""
        html = """
        <html>
            <head><title>Test Title</title></head>
            <body>
                <h1>Chapter 1</h1>
                <p>First paragraph with <strong>bold</strong> text.</p>
                <div>
                    <p>Second paragraph with <em>italic</em> text.</p>
                    <br>
                    <p>Third paragraph after break.</p>
                </div>
            </body>
        </html>
        """
        result = TextProcessor.html_to_plain_text(html)

        # Should remove title tag
        self.assertNotIn("Test Title", result)
        # Should contain the actual content
        self.assertIn("Chapter 1", result)
        self.assertIn("First paragraph with bold text", result)
        self.assertIn("Second paragraph with italic text", result)
        self.assertIn("Third paragraph after break", result)

    def test_html_to_plain_text_with_nbsp(self):
        """Test html_to_plain_text with non-breaking spaces"""
        html = "<p>Text&nbsp;with&nbsp;nbsp</p>"
        result = TextProcessor.html_to_plain_text(html)
        self.assertEqual(result, "Text with nbsp")

        html_unicode = "<p>Text\u00a0with\u00a0unicode\u00a0nbsp</p>"
        result_unicode = TextProcessor.html_to_plain_text(html_unicode)
        self.assertEqual(result_unicode, "Text with unicode nbsp")

    def test_html_to_plain_text_with_block_elements(self):
        """Test html_to_plain_text with block elements creating line breaks"""
        html = "<p>Para 1</p><div>Div content</div><br><li>List item</li>"
        result = TextProcessor.html_to_plain_text(html)

        # Should contain line breaks between block elements
        lines = result.split("\n")
        self.assertGreater(len(lines), 1)
        self.assertIn("Para 1", result)
        self.assertIn("Div content", result)
        self.assertIn("List item", result)

    def test_html_to_plain_text_whitespace_normalization(self):
        """Test html_to_plain_text normalizes whitespace"""
        html = "<p>Text   with    multiple     spaces</p>"
        result = TextProcessor.html_to_plain_text(html)
        self.assertEqual(result, "Text with multiple spaces")

        html_tabs = "<p>Text\t\twith\t\ttabs</p>"
        result_tabs = TextProcessor.html_to_plain_text(html_tabs)
        self.assertEqual(result_tabs, "Text with tabs")

    def test_html_to_plain_text_multiple_line_breaks(self):
        """Test html_to_plain_text normalizes multiple line breaks"""
        html = "<p>Para 1</p><br><br><br><p>Para 2</p>"
        result = TextProcessor.html_to_plain_text(html)

        # Should normalize multiple line breaks to double line break
        self.assertNotIn("\n\n\n", result)
        self.assertIn("Para 1", result)
        self.assertIn("Para 2", result)

    def test_extract_first_heading_empty_input(self):
        """Test extract_first_heading with empty input"""
        self.assertIsNone(TextProcessor.extract_first_heading(""))
        self.assertIsNone(TextProcessor.extract_first_heading(None))

    def test_extract_first_heading_no_headings(self):
        """Test extract_first_heading with no headings"""
        html = "<p>Just a paragraph without headings</p>"
        result = TextProcessor.extract_first_heading(html)
        self.assertIsNone(result)

    def test_extract_first_heading_h1(self):
        """Test extract_first_heading with H1"""
        html = "<h1>Chapter Title</h1><p>Content</p>"
        result = TextProcessor.extract_first_heading(html)
        self.assertEqual(result, "Chapter Title")

    def test_extract_first_heading_h2(self):
        """Test extract_first_heading with H2"""
        html = "<h2>Section Title</h2><p>Content</p>"
        result = TextProcessor.extract_first_heading(html)
        self.assertEqual(result, "Section Title")

    def test_extract_first_heading_multiple_headings(self):
        """Test extract_first_heading returns first heading only"""
        html = "<h1>First Heading</h1><h2>Second Heading</h2><p>Content</p>"
        result = TextProcessor.extract_first_heading(html)
        self.assertEqual(result, "First Heading")

    def test_extract_first_heading_with_html_tags(self):
        """Test extract_first_heading removes HTML tags from heading"""
        html = "<h1>Heading with <strong>bold</strong> and <em>italic</em></h1>"
        result = TextProcessor.extract_first_heading(html)
        self.assertEqual(result, "Heading with bold and italic")

    def test_extract_first_heading_case_insensitive(self):
        """Test extract_first_heading is case insensitive"""
        html = "<H1>UPPERCASE HEADING</H1>"
        result = TextProcessor.extract_first_heading(html)
        self.assertEqual(result, "UPPERCASE HEADING")

    def test_extract_first_heading_all_levels(self):
        """Test extract_first_heading works with all heading levels"""
        for level in range(1, 7):
            html = f"<h{level}>Heading Level {level}</h{level}>"
            result = TextProcessor.extract_first_heading(html)
            self.assertEqual(result, f"Heading Level {level}")

    def test_extract_title_from_text_empty_input(self):
        """Test extract_title_from_text with empty input"""
        self.assertEqual(TextProcessor.extract_title_from_text(""), "")
        self.assertEqual(TextProcessor.extract_title_from_text(None), "")
        self.assertEqual(TextProcessor.extract_title_from_text("   "), "")

    def test_extract_title_from_text_simple_text(self):
        """Test extract_title_from_text with simple text"""
        text = "This is a simple title text"
        result = TextProcessor.extract_title_from_text(text)
        self.assertEqual(result, "This is a simple title text")

    def test_extract_title_from_text_custom_word_count(self):
        """Test extract_title_from_text with custom word count"""
        text = "One two three four five six seven eight nine ten"
        result = TextProcessor.extract_title_from_text(text, max_words=3)
        self.assertEqual(result, "One two three")

        result = TextProcessor.extract_title_from_text(text, max_words=10)
        self.assertEqual(result, "One two three four five six seven eight nine ten")

    def test_extract_title_from_text_whitespace_normalization(self):
        """Test extract_title_from_text normalizes whitespace"""
        text = "Text   with    multiple     spaces    and\ttabs\nand\rcarriage\freturns"
        result = TextProcessor.extract_title_from_text(text)
        self.assertEqual(result, "Text with multiple spaces and tabs")

    def test_extract_title_from_text_fewer_words_than_max(self):
        """Test extract_title_from_text when text has fewer words than max"""
        text = "Only three words"
        result = TextProcessor.extract_title_from_text(text, max_words=10)
        self.assertEqual(result, "Only three words")

    def test_extract_title_from_text_single_word(self):
        """Test extract_title_from_text with single word"""
        text = "SingleWord"
        result = TextProcessor.extract_title_from_text(text)
        self.assertEqual(result, "SingleWord")

    def test_extract_title_from_text_with_punctuation(self):
        """Test extract_title_from_text preserves punctuation in words"""
        text = "Chapter 1: The Beginning of Something Great"
        result = TextProcessor.extract_title_from_text(text)
        self.assertEqual(result, "Chapter 1: The Beginning of Something")

    def test_collect_footnotes_fallback_handles_short_ids(self):
        """Fallback extraction should handle short footnote ids like 'fn1'."""
        markup = (
            '<p>Texto com nota<a href="#fn1">1</a>.</p>'
            '<section epub:type="footnotes">'
            '<p id="fn1"><a href="#ref-fn1">1</a> Nota explicativa detalhada.</p>'
            "</section>"
        )

        markup_with_markers, footnotes = TextProcessor._collect_footnotes_fallback(markup)

        self.assertIn("[[FOOTNOTE_1]]", markup_with_markers)
        self.assertEqual(len(footnotes), 1)
        self.assertIn("Nota explicativa", footnotes[0]["text"])

        plain_text, _ = TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
        rendered = TextProcessor._render_footnotes(
            plain_text, footnotes, mode="inline", context_words=8
        )

        self.assertIn("nota de rodapé 1", rendered.lower())

    def test_inject_footnotes_preserves_numeric_internal_section_link(self):
        """Numeric internal links (section anchors) must not be treated as footnotes."""
        markup = (
            '<h2><a href="#sec1">1</a></h2>'
            '<div id="sec1"><p>Primeira seção do capítulo.</p></div>'
        )

        processed_markup, footnotes = TextProcessor.inject_footnotes(markup)

        self.assertEqual(footnotes, [])
        self.assertIn(">1<", processed_markup)

        plain_text, _ = TextProcessor.html_to_plain_text_with_formatting(processed_markup)
        self.assertIn("1", plain_text)
        self.assertIn("Primeira seção do capítulo", plain_text)


class TestEnhanceNaturalPausesNewlines(unittest.TestCase):
    """Regression tests for enhance_natural_pauses newline preservation.

    Bug: re.sub with greedy whitespace around "..." consumed trailing newlines,
    collapsing multi-heading chapters onto a single line.  Fix: use [ \\t]*
    instead of \\s* so newlines are preserved.
    """

    def setUp(self):
        from src.text_formatting import TextFormattingProcessor

        self.enhance = TextFormattingProcessor.enhance_natural_pauses

    def test_newline_preserved_after_ellipsis(self):
        text = "Capítulo 20...\nO círculo se fecha..."
        result = self.enhance(text)
        self.assertIn("\n", result, "newline after '...' must be preserved")

    def test_heading_block_stays_multiline(self):
        text = "Capítulo 20...\nO círculo se fecha...\n1...\nTom...\nTom Rogan estava tendo"
        result = self.enhance(text)
        lines = [ln for ln in result.split("\n") if ln.strip()]
        self.assertGreaterEqual(len(lines), 5, "all heading lines must remain on separate lines")

    def test_section_number_on_own_line(self):
        text = "Capítulo 20...\nO círculo se fecha...\n1...\nTom...\nBody text here."
        result = self.enhance(text)
        self.assertIn("\n1", result, "section number '1' must remain on its own line")

    def test_person_name_heading_on_own_line(self):
        text = "Capítulo 20...\nO círculo se fecha...\n1...\nTom...\nBody text here."
        result = self.enhance(text)
        self.assertIn("\nTom", result, "person name 'Tom' must remain on its own line")

    def test_ellipsis_spacing_normalised(self):
        text = "Texto com  ...  espaço."
        result = self.enhance(text)
        self.assertNotIn("  ...", result)
        self.assertNotIn("...  ", result)

    def test_paragraph_break_preserved(self):
        text = "He paused...\n\nNew paragraph starts."
        result = self.enhance(text)
        self.assertIn("\n\n", result, "double newline paragraph break must survive")


class TestITChapter20SpeechPipeline(unittest.TestCase):
    """End-to-end tests for the IT ch.20 heading structure.

    HTML structure (pt-BR IT edition, part0037.xhtml):
      <p class_s3J-0>Capítulo 20</p>
      <p class_s3M-0>O círculo se fecha</p>
      <p class_s3P-0>1</p>          ← section number (SUBCHAPTER_NUMBER_CLASSES)
      <p class_sG5>Tom</p>          ← section title  (SUBCHAPTER_TITLE_CLASS)
      <p ...>Tom Rogan estava tendo uma porra de sonho louco.</p>

    Expected pre-tts: each structural element on its own line followed by "..."
    for a natural TTS pause.
    """

    IT_CH20_HTML = (
        '<div class="class_s11-0">'
        '<p class="class_s3J-0">Capítulo 20</p>'
        '<p class="class_s3M-0">O círculo se fecha</p>'
        '<p class="class_s3P-0">1</p>'
        '<p class="class_sG5">Tom</p>'
        '<p class="class_s1S-0">Tom Rogan estava tendo uma porra de sonho louco.</p>'
        "</div>"
    )

    def _speech_text(self, html, chapter_title="Capítulo 20 – O círculo se fecha"):
        from src.ebook_reader import TextProcessor
        from src.text_formatting import TextFormattingProcessor

        plain, segs = TextProcessor.html_to_plain_text_with_formatting(html)
        formatter = TextFormattingProcessor()
        audible = formatter.to_audible_text(plain, segs)
        structured = TextProcessor.apply_structural_speech_cues(
            audible, raw_html=html, chapter_title=chapter_title
        )
        return TextFormattingProcessor.enhance_natural_pauses(structured)

    def test_chapter_number_in_speech(self):
        result = self._speech_text(self.IT_CH20_HTML)
        self.assertIn("Capítulo 20", result)

    def test_chapter_title_in_speech(self):
        result = self._speech_text(self.IT_CH20_HTML)
        self.assertIn("círculo se fecha", result)

    def test_section_number_in_speech(self):
        result = self._speech_text(self.IT_CH20_HTML)
        self.assertIn("1", result)

    def test_person_name_in_speech(self):
        result = self._speech_text(self.IT_CH20_HTML)
        self.assertIn("Tom", result)

    def test_body_text_in_speech(self):
        result = self._speech_text(self.IT_CH20_HTML)
        self.assertIn("Tom Rogan estava tendo", result)

    def test_section_number_on_separate_line(self):
        result = self._speech_text(self.IT_CH20_HTML)
        lines = [ln.strip().rstrip(".") for ln in result.split("\n") if ln.strip()]
        # "1" should appear as its own line (possibly with "..." appended)
        section_lines = [ln for ln in lines if ln == "1" or ln.startswith("1.")]
        self.assertTrue(section_lines, f"'1' must be on its own line; got:\n{result}")

    def test_person_name_on_separate_line(self):
        result = self._speech_text(self.IT_CH20_HTML)
        lines = [ln.strip() for ln in result.split("\n") if ln.strip()]
        # "Tom" heading line (NOT the body sentence "Tom Rogan estava...")
        tom_heading = [ln for ln in lines if ln.rstrip(". ").rstrip(".") == "Tom"]
        self.assertTrue(tom_heading, f"'Tom' must be on its own line; got:\n{result}")

    def test_headings_not_run_together(self):
        result = self._speech_text(self.IT_CH20_HTML)
        # If headings are collapsed, "O círculo se fechaTom Rogan" would appear
        self.assertNotIn("fechaTom", result)
        self.assertNotIn("fecha1", result)
        self.assertNotIn("fecha Tom", result.replace("\n", ""))

    def test_chapter_number_not_duplicated_in_toc_title(self):
        # When the text already starts with the chapter number heading,
        # apply_structural_speech_cues must NOT prepend the TOC title again.
        result = self._speech_text(self.IT_CH20_HTML)
        self.assertLessEqual(
            result.lower().count("capítulo 20"),
            1,
            "chapter number must not be spoken twice",
        )


class TestITChapter20Section3SpeechPipeline(unittest.TestCase):
    """End-to-end tests for IT ch.20 section 3 heading structure.

    HTML structure (pt-BR IT edition, part0037.xhtml):
      <p class_s42-0>3</p>           ← section number (SUBCHAPTER_NUMBER_CLASSES)
      <p class_sG5>Quarto de Eddie</p> ← section title  (SUBCHAPTER_TITLE_CLASS)
      <p class_s1S-0>Beverly e Bill...</p>

    Expected pre-tts: section number and title each on their own line with "..."
    followed by body text on the next line.
    """

    IT_CH20_S3_HTML = (
        '<div class="class_s11-0">'
        '<p class="class_s42-0">3</p>'
        '<p class="class_sG5">Quarto de Eddie</p>'
        '<p class="class_s1S-0">Beverly e Bill se vestiram rapidamente, sem falar, e subiram para o quarto de Eddie.</p>'
        "</div>"
    )

    def _speech_text(self, html, chapter_title="Capítulo 20 – O círculo se fecha"):
        from src.ebook_reader import TextProcessor
        from src.text_formatting import TextFormattingProcessor

        plain, segs = TextProcessor.html_to_plain_text_with_formatting(html)
        formatter = TextFormattingProcessor()
        audible = formatter.to_audible_text(plain, segs)
        structured = TextProcessor.apply_structural_speech_cues(
            audible, raw_html=html, chapter_title=chapter_title
        )
        return TextFormattingProcessor.enhance_natural_pauses(structured)

    def test_section_number_in_speech(self):
        result = self._speech_text(self.IT_CH20_S3_HTML)
        self.assertIn("3", result)

    def test_section_title_in_speech(self):
        result = self._speech_text(self.IT_CH20_S3_HTML)
        self.assertIn("Quarto de Eddie", result)

    def test_body_text_in_speech(self):
        result = self._speech_text(self.IT_CH20_S3_HTML)
        self.assertIn("Beverly e Bill se vestiram rapidamente", result)

    def test_section_number_on_separate_line(self):
        result = self._speech_text(self.IT_CH20_S3_HTML)
        lines = [ln.strip().rstrip(".") for ln in result.split("\n") if ln.strip()]
        section_lines = [ln for ln in lines if ln == "3" or ln.startswith("3.")]
        self.assertTrue(section_lines, f"'3' must be on its own line; got:\n{result}")

    def test_section_title_on_separate_line(self):
        result = self._speech_text(self.IT_CH20_S3_HTML)
        lines = [ln.strip() for ln in result.split("\n") if ln.strip()]
        title_lines = [ln for ln in lines if ln.rstrip(". ").rstrip(".") == "Quarto de Eddie"]
        self.assertTrue(title_lines, f"'Quarto de Eddie' must be on its own line; got:\n{result}")

    def test_headings_not_run_together(self):
        result = self._speech_text(self.IT_CH20_S3_HTML)
        # If headings collapse: "3Quarto de Eddie" or "3 Quarto de Eddie" on same line
        self.assertNotIn("3Quarto", result)
        flat = result.replace("\n", "")
        self.assertNotIn("3Quarto", flat)
        self.assertNotIn("EddieBeverly", flat)

    def test_section_number_before_title(self):
        result = self._speech_text(self.IT_CH20_S3_HTML)
        idx_3 = result.find("3")
        idx_title = result.find("Quarto de Eddie")
        self.assertLess(idx_3, idx_title, "'3' must appear before 'Quarto de Eddie'")

    def test_title_before_body(self):
        result = self._speech_text(self.IT_CH20_S3_HTML)
        idx_title = result.find("Quarto de Eddie")
        idx_body = result.find("Beverly e Bill se vestiram")
        self.assertLess(idx_title, idx_body, "'Quarto de Eddie' must appear before body text")


if __name__ == "__main__":
    unittest.main()
