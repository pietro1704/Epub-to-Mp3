"""Paragraph fallback scenarios sharing the original unittest fixture."""

from python_app.tests._ebook_reader_test_support import EpubParser as EpubParser


class ParagraphFallbackCases:
    def test_paragraph_split_oversized_chapter(self):
        """Chapters exceeding SUBCHAPTER_MAX_CHARS are split at line boundaries
        and get a dash-suffix index (e.g. "7-1", "7-2")."""
        # EPUB plain text uses single \n between paragraphs.
        para = "Word " * 200  # ~1 000 chars each
        text = "\n".join([para] * 60)  # ~60 000 chars total

        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 7)

        self.assertGreater(len(result), 1)
        for idx, chunk in result:
            self.assertTrue(idx.startswith("7-"), f"Expected dash index, got {idx!r}")
        # Each chunk should not vastly exceed the limit (some slack for last line).
        for _, chunk in result:
            self.assertLessEqual(len(chunk), 55_000)

    def test_paragraph_split_small_chapter_unchanged(self):
        """Small chapters are returned as-is with the original (non-decimal) index."""
        text = "Short chapter.\nSecond paragraph."
        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 3)

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0][0], "3")
        self.assertEqual(result[0][1], text)

    def test_paragraph_split_exact_boundary(self):
        """A chapter that barely fits is returned with the original index."""
        text = "A" * 49_999
        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 2)

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0][0], "2")

    def test_paragraph_split_uses_dash_suffix(self):
        """Paragraph-boundary splits use a dash suffix ("N-1", "N-2") so they
        are visually distinct from CSS-marker decimal splits ("N.1", "N.2")."""
        para = "Paragraph text. " * 50  # ~800 chars each
        text = "\n".join([para] * 10)  # ~8 000 chars total
        result = EpubParser._split_text_at_paragraph_boundaries(text, 3_000, 4)

        self.assertGreater(len(result), 1)
        for i, (idx, _) in enumerate(result, 1):
            self.assertEqual(idx, f"4-{i}", f"Expected '4-{i}', got {idx!r}")

    def test_paragraph_split_dash_with_string_parent_index(self):
        """Dash suffix also works when parent_index is a hierarchical string."""
        para = "Long paragraph content. " * 60  # ~1 440 chars each
        text = "\n".join([para] * 20)  # ~28 800 chars total
        result = EpubParser._split_text_at_paragraph_boundaries(text, 10_000, "5.1.3")

        self.assertGreater(len(result), 1)
        for i, (idx, _) in enumerate(result, 1):
            self.assertEqual(idx, f"5.1.3-{i}", f"Expected '5.1.3-{i}', got {idx!r}")

    def test_paragraph_split_long_single_line_uses_epub_parser_splitter(self):
        """A single oversized line is force-split without calling EbookReader."""
        text = "word " * 15_000

        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 9)

        self.assertGreater(len(result), 1)
        for idx, chunk in result:
            self.assertTrue(idx.startswith("9-"), f"Expected dash index, got {idx!r}")
            self.assertLessEqual(len(chunk), 50_000)
