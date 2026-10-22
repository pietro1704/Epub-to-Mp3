"""Compatibility at the ebook parser and speech-preparation boundaries."""

from collections import OrderedDict
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch

from python_app.src import ebook_reader as runtime
from python_app.src.ebook_models import Book, Chapter, CoverImage, TocItem
from python_app.src.ebook_pdf_parser import PdfParser


class EbookParsingBoundaryTests(TestCase):
    def test_public_models_and_pdf_parser_keep_one_identity(self):
        for name, expected in [
            ("Book", Book),
            ("Chapter", Chapter),
            ("CoverImage", CoverImage),
            ("TocItem", TocItem),
            ("PdfParser", PdfParser),
        ]:
            self.assertIs(getattr(runtime, name), expected)

    def test_missing_book_reports_failure(self):
        with TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                runtime.EbookReader(Path(directory) / "missing.epub")

    def test_speech_title_announcement_preserves_body(self):
        result = runtime.TextProcessor.apply_structural_speech_cues(
            "The story begins here.", chapter_title="A Long Expected Party"
        )
        self.assertIn("A Long Expected Party", result)
        self.assertIn("The story begins here.", result)

    def test_html_filtering_preserves_prose_and_excludes_scripts(self):
        result = runtime.TextProcessor.html_to_plain_text(
            "<p>First paragraph.</p><script>discard()</script><p>Second paragraph.</p>"
        )
        self.assertIn("First paragraph.", result)
        self.assertIn("Second paragraph.", result)
        self.assertNotIn("discard", result)

    def test_toc_cache_uses_facade_budget_and_returns_snapshots(self):
        with TemporaryDirectory() as directory:
            source = Path(directory) / "book.epub"
            source.touch()
            item = TocItem(title="Chapter", href="chapter.xhtml", level=1)
            with (
                patch.object(runtime, "_toc_cache", OrderedDict()),
                patch.object(runtime, "_TOC_CACHE_MAX", 1),
                patch.object(runtime, "_toc_disk_cache_path", return_value=None),
                patch.object(runtime, "_toc_disk_cache_cleanup", return_value=0),
            ):
                runtime._toc_cache_put(str(source), "content.opf", [item])
                first = runtime._toc_cache_get(str(source), "content.opf")
                self.assertIs(first[0], item)
                first.clear()
                self.assertEqual(runtime._toc_cache_get(str(source), "content.opf"), [item])
                self.assertIsNone(runtime._toc_cache_get(str(source), "other.opf"))
