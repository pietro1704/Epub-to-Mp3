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

        html_unicode = "<p>Text\u00A0with\u00A0unicode\u00A0nbsp</p>"
        result_unicode = TextProcessor.html_to_plain_text(html_unicode)
        self.assertEqual(result_unicode, "Text with unicode nbsp")

    def test_html_to_plain_text_with_block_elements(self):
        """Test html_to_plain_text with block elements creating line breaks"""
        html = "<p>Para 1</p><div>Div content</div><br><li>List item</li>"
        result = TextProcessor.html_to_plain_text(html)
        
        # Should contain line breaks between block elements
        lines = result.split('\n')
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
            "<p>Texto com nota<a href=\"#fn1\">1</a>.</p>"
            "<section epub:type=\"footnotes\">"
            "<p id=\"fn1\"><a href=\"#ref-fn1\">1</a> Nota explicativa detalhada.</p>"
            "</section>"
        )

        markup_with_markers, footnotes = TextProcessor._collect_footnotes_fallback(markup)

        self.assertIn("[[FOOTNOTE_1]]", markup_with_markers)
        self.assertEqual(len(footnotes), 1)
        self.assertIn("Nota explicativa", footnotes[0]["text"])

        plain_text, _ = TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
        rendered = TextProcessor._render_footnotes(plain_text, footnotes, mode="inline", context_words=8)

        self.assertIn("nota de rodapé 1", rendered.lower())


if __name__ == '__main__':
    unittest.main()
