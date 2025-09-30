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

from src.ebook_reader import EbookReader
from main import ConverterApplication

FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures" / "epubs"
SAMPLE_EPUB = FIXTURE_ROOT / "test_multifeature.epub"


class TestSampleEpubFeatures(unittest.TestCase):
    """Validate parsing features present in the bundled sample EPUB."""

    def setUp(self) -> None:
        if not SAMPLE_EPUB.exists():  # pragma: no cover - guard for optional installs
            self.skipTest("Sample EPUB fixture not found")

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
        italic_pt = {seg.text for seg in chapter_one.formatting_segments or [] if getattr(seg, 'formatting', '') == 'italic'}
        self.assertIn('“Olhe além do esperado”', italic_pt)
        self.assertIn('“Continue acreditando”', italic_pt)
        self.assertIn("nota de rodapé", chapter_one.text.lower())
        self.assertIn("Seção 2 - Correspondência", chapter_one.text)
        if getattr(chapter_one, 'speech_text', None):
            self.assertNotIn('_', chapter_one.speech_text)

        chapter_two = chapters[1]
        self.assertIn("The letter begins", chapter_two.text)
        self.assertIn("“Confía en tu instinto”", chapter_two.text)
        self.assertIn("“Seguirei acreditando”", chapter_two.text)
        italic_foreign = {seg.text for seg in chapter_two.formatting_segments or [] if getattr(seg, 'formatting', '') == 'italic'}
        self.assertIn('“look beyond the obvious”', {text.lower() for text in italic_foreign})
        self.assertTrue(any('Confía en tu instinto' in text for text in italic_foreign))
        self.assertTrue(any('Seguirei acreditando' in text for text in italic_foreign))

        toc = reader.get_toc()
        self.assertEqual(len(toc), 2)
        self.assertEqual(toc[0].title, "Capítulo 1 - Começo")
        self.assertEqual(len(toc[0].children), 3)
        self.assertEqual(toc[0].children[0].title, "Seção 1 - Diário")
        self.assertEqual(toc[0].children[2].href, "chapter1.xhtml#notas")

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

                args = type("Args", (), {
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
                })

                # Capture output just to ensure the command runs without errors
                with io.StringIO() as buffer, unittest.mock.patch("sys.stdout", buffer):
                    result = app.run(args)  # type: ignore[arg-type]
                    self.assertEqual(result, 0)

                cache_dir = app.cache_root / "Test_Multi_Feature_Book" / "txt"
                self.assertTrue(cache_dir.exists())

                cached_files = sorted(cache_dir.glob("*.txt"))
                self.assertGreaterEqual(len(cached_files), 3)

                preview_reader = EbookReader(sample_copy)
                preview_items = app._generate_structure_items(preview_reader)
                preview_config = app.config.create_conversion_config(
                    engine="edge",
                    output_dir=str(app.cache_root),
                    book_title=preview_reader.title,
                )
                transformed = app._apply_text_transforms(preview_items, preview_config, preview_reader)
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


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
