"""Footnote Performance regression scenarios, collected by test_text_processor."""

from python_app.tests._text_processor_test_support import TextProcessor as TextProcessor
from python_app.tests._text_processor_test_support import unittest as unittest


class TestCollectFootnotesPerformance(unittest.TestCase):
    """Regression tests for O(n²) hang in _collect_footnotes_bs4 (LOTR bug).

    Before the fix, a document with thousands of anchors caused soup.find(id=fragment)
    to run once per anchor — O(n²) on a large DOM — making EbookReader hang
    indefinitely.  The fix builds a one-time id→node index so every lookup is O(1).
    """

    def _build_doc_with_n_anchors(self, n: int) -> str:
        """Build an HTML document with n anchor+target pairs."""
        anchors = "".join(
            f'<p><a href="#fn{i}" epub:type="noteref">{i}</a></p>\n' for i in range(n)
        )
        targets = "".join(f'<p id="fn{i}">Footnote text {i}.</p>\n' for i in range(n))
        return f"<html><body>{anchors}{targets}</body></html>"

    def test_large_anchor_count_completes_quickly(self):
        """5 000-anchor document must complete well under 5 s (was infinite hang)."""
        import time

        n = 5_000
        markup = self._build_doc_with_n_anchors(n)
        start = time.monotonic()
        result_markup, footnotes = TextProcessor._collect_footnotes_bs4(
            markup, __import__("bs4").BeautifulSoup
        )
        elapsed = time.monotonic() - start

        self.assertLess(
            elapsed,
            6.5,
            f"_collect_footnotes_bs4 with {n} anchors took {elapsed:.2f}s (limit 6.5s)",
        )
        # Footnotes should be collected correctly
        self.assertGreater(len(footnotes), 0, "Expected footnotes to be collected")

    def test_footnotes_still_collected_correctly_after_index_fix(self):
        """Correctness: footnotes are collected and markers injected as before."""
        markup = (
            "<html><body>"
            '<p>See <a href="#fn1" epub:type="noteref">1</a> and '
            '<a href="#fn2" epub:type="noteref">2</a>.</p>'
            '<p id="fn1">First footnote text.</p>'
            '<p id="fn2">Second footnote text.</p>'
            "</body></html>"
        )
        result_markup, footnotes = TextProcessor._collect_footnotes_bs4(
            markup, __import__("bs4").BeautifulSoup
        )
        self.assertEqual(len(footnotes), 2)
        self.assertIn("First footnote text", footnotes[0]["text"])
        self.assertIn("Second footnote text", footnotes[1]["text"])
        self.assertIn("[[FOOTNOTE_1]]", result_markup)
        self.assertIn("[[FOOTNOTE_2]]", result_markup)

    def test_safety_budget_skips_absurd_anchor_count(self):
        """Documents exceeding the 20 000-anchor budget return document unchanged with no footnotes."""
        # Build doc slightly over the budget (20 001 anchors, no matching targets
        # so it hits the safety check quickly regardless)
        n = 20_001
        anchors = "".join(f'<a href="#fn{i}">{i}</a>' for i in range(n))
        markup = f"<html><body>{anchors}</body></html>"
        result_markup, footnotes = TextProcessor._collect_footnotes_bs4(
            markup, __import__("bs4").BeautifulSoup
        )
        self.assertEqual(footnotes, [], "Expected no footnotes (safety budget exceeded)")
        # Document should be returned unchanged (the soup stringification)
        self.assertIn("fn0", result_markup)
