# -*- coding: utf-8 -*-
"""Tests for enriched sample EPUB used across the suite."""

from __future__ import annotations

import io
import os
import shutil
import tempfile
import unittest
import unittest.mock
from pathlib import Path

from main import ConverterApplication
from src.ebook_reader import EbookReader, EpubParser
from src.text_formatting import TextFormattingProcessor

FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures" / "epubs"
SAMPLE_EPUB = FIXTURE_ROOT / "test_multifeature.epub"
SAMPLE_MULTILANG = FIXTURE_ROOT / "sample_multilang.epub"


class TestSampleEpubFeatures(unittest.TestCase):
    """Validate parsing features present in the bundled sample EPUB."""

    def setUp(self) -> None:
        self.assertTrue(SAMPLE_EPUB.exists())

    def test_epub_reader_extracts_multifeature_content(self) -> None:
        reader = EbookReader(SAMPLE_EPUB)

        self.assertEqual(reader.title, "Test Multi Feature Book")
        self.assertEqual(reader.author, "Equipe de Testes")

        chapters = reader.get_chapters()
        self.assertEqual(len(chapters), 2)

        chapter_one = chapters[0]
        self.assertIn("Capítulo 1 - Começo", chapter_one.name)
        self.assertIn("_itálico_", chapter_one.text)
        self.assertIn("“Olhe além do esperado”", chapter_one.text)
        italic_pt = {
            seg.text
            for seg in chapter_one.formatting_segments or []
            if getattr(seg, "formatting", "") == "italic"
        }
        self.assertIn("“Olhe além do esperado”", italic_pt)
        self.assertIn("“Continue acreditando”", italic_pt)
        self.assertIn("nota de rodapé", chapter_one.text.lower())
        self.assertIn("Seção 2 - Correspondência", chapter_one.text)
        if getattr(chapter_one, "speech_text", None):
            self.assertNotIn("_", chapter_one.speech_text)

        chapter_two = chapters[1]
        self.assertIn("The letter begins", chapter_two.text)
        self.assertIn("“Confía en tu instinto”", chapter_two.text)
        self.assertIn("“Seguirei acreditando”", chapter_two.text)
        italic_foreign = {
            seg.text
            for seg in chapter_two.formatting_segments or []
            if getattr(seg, "formatting", "") == "italic"
        }
        self.assertIn("“look beyond the obvious”", {text.lower() for text in italic_foreign})
        self.assertTrue(any("Confía en tu instinto" in text for text in italic_foreign))
        self.assertTrue(any("Seguirei acreditando" in text for text in italic_foreign))

        toc = reader.get_toc()
        self.assertEqual(len(toc), 2)
        self.assertEqual(toc[0].title, "Capítulo 1 - Começo")
        self.assertEqual(len(toc[0].children), 3)
        self.assertEqual(toc[0].children[0].title, "Seção 1 - Diário")
        self.assertEqual(toc[0].children[2].href, "chapter1.xhtml#notas")

    def test_prepare_speech_text_adds_small_pause_on_line_breaks(self) -> None:
        source = "Chapter 1\nTHE BOY WHO LIVED\nMr. and Mrs. Dursley were proud."

        speech = EpubParser._prepare_speech_text(source, formatting_segments=None)

        self.assertIn("Chapter 1.", speech)
        self.assertIn("THE BOY WHO LIVED.", speech)
        self.assertIn("Mr. and Mrs. Dursley were proud.", speech)

    def test_enhance_natural_pauses_handles_heading_breaks_generically(self) -> None:
        source = "12\nA New Beginning\nThe story starts here."

        enhanced = TextFormattingProcessor.enhance_natural_pauses(source)

        self.assertIn("12.", enhanced)
        self.assertIn("A New Beginning.", enhanced)
        self.assertTrue(enhanced.endswith("The story starts here."))

    def test_show_structure_generates_cached_text(self) -> None:
        """End-to-end check ensuring cached text matches prepared chapter output."""
        temp_dir = tempfile.mkdtemp(prefix="epub-multifeature-")
        try:
            # Work inside a temp directory so we control the cache folder
            cwd = os.getcwd()
            os.chdir(temp_dir)
            try:
                sample_copy = Path(temp_dir) / "sample.epub"
                shutil.copy2(SAMPLE_EPUB, sample_copy)

                app = ConverterApplication()
                app.cache_root = Path(temp_dir) / ".cache"

                args = type(
                    "Args",
                    (),
                    {
                        "input_file": str(sample_copy),
                        "show_structure": True,
                        "engine": None,
                        "voice": None,
                        "model": None,
                        "output_dir": None,
                        "filter_chapters": False,
                        "parallel": None,
                        "clear_cache": False,
                        "chapters": [],
                        "sections": [],
                        "menu": False,
                    },
                )

                # Capture output just to ensure the command runs without errors
                with io.StringIO() as buffer, unittest.mock.patch("sys.stdout", buffer):
                    result = app.run(args)  # type: ignore[arg-type]
                    self.assertEqual(result, 0)

                # Cache is saved using ebook_path.stem (sample.epub -> sample)
                cache_dir = app.cache_root / "sample" / "txt"
                self.assertTrue(cache_dir.exists(), f"Cache directory not found at {cache_dir}")

                cached_files = sorted(cache_dir.glob("*.txt"))
                self.assertGreaterEqual(len(cached_files), 3)

                preview_reader = EbookReader(sample_copy)
                preview_items = app._generate_structure_items(preview_reader)
                preview_config = app.config.create_conversion_config(
                    engine="edge",
                    output_dir=str(app.cache_root),
                    book_title=preview_reader.title,
                )
                transformed = app._apply_text_transforms(
                    preview_items, preview_config, preview_reader
                )
                self.assertEqual(len(transformed), len(cached_files))

                cached_texts = []
                for transformed_item, cached_file in zip(transformed, cached_files):
                    cached_text = cached_file.read_text(encoding="utf-8").strip()
                    self.assertEqual(cached_text, (transformed_item.text_override or "").strip())
                    cached_texts.append(cached_text)
                    if "*" in cached_text:
                        self.assertIn("*", transformed_item.text_override or "")

                # Ensure we are not duplicating full texts across sections
                self.assertEqual(len(set(cached_texts)), len(cached_texts))
            finally:
                os.chdir(cwd)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)


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


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
