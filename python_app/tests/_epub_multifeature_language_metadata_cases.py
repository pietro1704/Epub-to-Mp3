"""Language Metadata regression scenarios, collected by test_epub_multifeature."""

from __future__ import annotations

from python_app.tests._epub_multifeature_test_support import SAMPLE_MULTILANG as SAMPLE_MULTILANG
from python_app.tests._epub_multifeature_test_support import EbookReader as EbookReader
from python_app.tests._epub_multifeature_test_support import (
    TextFormattingProcessor as TextFormattingProcessor,
)
from python_app.tests._epub_multifeature_test_support import unittest as unittest


class TestLanguageAttributeExtraction(unittest.TestCase):
    """Test lang attribute extraction from HTML"""

    def test_extract_single_lang_attribute(self) -> None:
        """Test extracting lang from a single tag"""
        formatter = TextFormattingProcessor()
        html = '<p lang="en">Hello world</p>'
        result = formatter._extract_language_attributes(html)

        self.assertIn("[[lang:en]]", result)
        self.assertIn("[[/lang]]", result)
        self.assertIn("Hello world", result)

    def test_extract_multiple_lang_attributes(self) -> None:
        """Test extracting lang from multiple tags"""
        formatter = TextFormattingProcessor()
        html = '<p lang="en">Hello</p><p lang="es">Hola</p><p lang="pt-BR">Olá</p>'
        result = formatter._extract_language_attributes(html)

        self.assertIn("[[lang:en]]", result)
        self.assertIn("[[lang:es]]", result)
        self.assertIn("[[lang:pt-BR]]", result)
        self.assertEqual(result.count("[[lang:"), 3)
        self.assertEqual(result.count("[[/lang]]"), 3)

    def test_extract_nested_lang_attributes(self) -> None:
        """Test that nested lang tags are handled correctly (inner takes precedence)"""
        formatter = TextFormattingProcessor()
        html = '<html lang="pt"><body><p lang="en">Hello</p><p lang="es">Hola</p></body></html>'
        result = formatter._extract_language_attributes(html)

        # Should have lang:en and lang:es for paragraphs
        self.assertIn("[[lang:en]]", result)
        self.assertIn("[[lang:es]]", result)
        # May also have outer pt tag
        self.assertIn("Hello", result)
        self.assertIn("Hola", result)

    def test_extract_xml_lang_attribute(self) -> None:
        """Test extracting xml:lang attribute"""
        formatter = TextFormattingProcessor()
        html = '<p xml:lang="fr">Bonjour</p>'
        result = formatter._extract_language_attributes(html)

        self.assertIn("[[lang:fr]]", result)
        self.assertIn("Bonjour", result)

    def test_no_lang_attribute(self) -> None:
        """Test that text without lang attribute is unchanged"""
        formatter = TextFormattingProcessor()
        html = "<p>Plain text</p>"
        result = formatter._extract_language_attributes(html)

        self.assertNotIn("[[lang:", result)
        self.assertEqual(html, result)


class TestMultilangEpubParsing(unittest.TestCase):
    """Test EPUB parsing with multiple language attributes"""

    def setUp(self) -> None:
        self.assertTrue(SAMPLE_MULTILANG.exists())

    def test_multilang_epub_extracts_language_tags(self) -> None:
        """Test that language tags are extracted from multilang EPUB"""
        reader = EbookReader(SAMPLE_MULTILANG)

        chapters = reader.get_chapters()
        self.assertGreaterEqual(len(chapters), 2)

        # Find chapter 2 "Correspondências" which has multilang content
        multilang_chapter = None
        for ch in chapters:
            if "Correspondências" in ch.name:
                multilang_chapter = ch
                break

        self.assertIsNotNone(multilang_chapter, "Chapter 2 'Correspondências' not found")

        # Check that language tags were extracted
        text = multilang_chapter.text
        self.assertIn("[[lang:", text, "No language tags found in text")

        # Check for specific language tags (en, es should be present)
        has_en = "[[lang:en]]" in text
        has_es = "[[lang:es]]" in text

        self.assertTrue(has_en and has_es, f"Expected EN and ES language tags. Text: {text[:200]}")

    def test_multilang_chapter_content_preserved(self) -> None:
        """Test that multilang content is preserved with correct language tags"""
        reader = EbookReader(SAMPLE_MULTILANG)
        chapters = reader.get_chapters()

        # Find chapter 2
        ch2 = None
        for ch in chapters:
            if "Correspondências" in ch.name:
                ch2 = ch
                break

        self.assertIsNotNone(ch2)

        # Check that all three language segments are present
        self.assertIn("The letter begins", ch2.text)  # English
        self.assertIn("Más adelante", ch2.text)  # Spanish
        self.assertIn("O destinatário", ch2.text)  # Portuguese
