"""Numeric Headings regression scenarios, collected by test_ebook_reader."""

from python_app.tests._ebook_reader_test_support import EpubParser as EpubParser
from python_app.tests._ebook_reader_test_support import unittest as unittest


class TestNumericHeadingSplitter(unittest.TestCase):
    """Tests for EpubParser._split_html_on_numeric_headings."""

    def _split(self, markup, parent_index="5.1", heading_tags=("h3",)):
        return EpubParser._split_html_on_numeric_headings(markup, parent_index, heading_tags)

    # --- None / insufficient headings ---

    def test_returns_none_when_no_numeric_headings(self):
        markup = "<p>Some content without headings.</p>"
        self.assertIsNone(self._split(markup))

    def test_returns_none_when_only_one_numeric_heading(self):
        markup = "<h3>1</h3><p>Only one section.</p>"
        self.assertIsNone(self._split(markup))

    def test_returns_none_when_only_non_numeric_headings(self):
        markup = "<h3>Introduction</h3><p>First.</p><h3>Conclusion</h3><p>Last.</p>"
        self.assertIsNone(self._split(markup))

    def test_returns_none_for_empty_markup(self):
        self.assertIsNone(self._split(""))

    # --- Correct splitting ---

    def test_splits_at_two_numeric_headings(self):
        markup = "<h3>1</h3><p>Section one content.</p><h3>2</h3><p>Section two content.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)

    def test_splits_at_three_numeric_headings(self):
        markup = "<h3>1</h3><p>Alpha.</p>" "<h3>2</h3><p>Beta.</p>" "<h3>3</h3><p>Gamma.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 3)

    # --- Sub-index format ---

    def test_sub_index_format_uses_parent_dot_n(self):
        markup = "<h3>1</h3><p>A.</p><h3>2</h3><p>B.</p>"
        result = self._split(markup, parent_index="5.1")
        self.assertIsNotNone(result)
        indices = [item[0] for item in result]
        self.assertEqual(indices, ["5.1.1", "5.1.2"])

    def test_sub_index_format_with_simple_parent_index(self):
        markup = "<h3>1</h3><p>A.</p><h3>2</h3><p>B.</p><h3>3</h3><p>C.</p>"
        result = self._split(markup, parent_index="3")
        self.assertIsNotNone(result)
        indices = [item[0] for item in result]
        self.assertEqual(indices, ["3.1", "3.2", "3.3"])

    # --- Non-numeric headings are ignored ---

    def test_non_numeric_headings_are_ignored(self):
        markup = (
            "<h3>Introduction</h3><p>Preamble text.</p>"
            "<h3>1</h3><p>First section.</p>"
            "<h3>2</h3><p>Second section.</p>"
        )
        result = self._split(markup, parent_index="4")
        self.assertIsNotNone(result)
        # Only the two numeric headings produce sections
        self.assertEqual(len(result), 2)
        indices = [item[0] for item in result]
        self.assertEqual(indices, ["4.1", "4.2"])

    def test_mixed_text_heading_does_not_qualify(self):
        markup = "<h3>Chapter One</h3><p>A.</p><h3>1</h3><p>B.</p><h3>2</h3><p>C.</p>"
        result = self._split(markup, parent_index="2")
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)

    # --- has_explicit_title is always False ---

    def test_has_explicit_title_is_false_for_all_items(self):
        markup = "<h3>1</h3><p>A.</p><h3>2</h3><p>B.</p><h3>3</h3><p>C.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        for sub_index, sub_title, html_fragment, has_explicit_title in result:
            self.assertFalse(
                has_explicit_title,
                f"has_explicit_title should be False for '{sub_index}', got {has_explicit_title}",
            )

    # --- Preamble prepended to section 1 ---

    def test_preamble_is_prepended_to_first_section_fragment(self):
        preamble = "<p>Book preamble before any section.</p>"
        markup = f"{preamble}<h3>1</h3><p>Section one.</p><h3>2</h3><p>Section two.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        # The preamble must appear only in the first fragment
        first_fragment = result[0][2]
        self.assertIn("preamble", first_fragment)
        # Second fragment should NOT contain the preamble text
        second_fragment = result[1][2]
        self.assertNotIn("preamble", second_fragment)

    def test_no_preamble_when_heading_is_first(self):
        markup = "<h3>1</h3><p>Immediate start.</p><h3>2</h3><p>Second.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        first_fragment = result[0][2]
        # Fragment starts at the heading — no extra preamble inserted
        self.assertTrue(first_fragment.startswith("<h3>1</h3>"))

    # --- Tuple structure ---

    def test_each_item_is_four_tuple(self):
        markup = "<h3>1</h3><p>A.</p><h3>2</h3><p>B.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        for item in result:
            self.assertEqual(len(item), 4, f"Each item must be a 4-tuple, got {item}")

    # --- Alternative heading tags ---

    def test_custom_heading_tag_h2(self):
        markup = "<h2>1</h2><p>A.</p><h2>2</h2><p>B.</p>"
        result = self._split(markup, heading_tags=("h2",))
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)

    def test_default_h3_does_not_match_h2(self):
        """Default heading_tags=('h3',) should not match <h2> elements."""
        markup = "<h2>1</h2><p>A.</p><h2>2</h2><p>B.</p>"
        result = self._split(markup)
        self.assertIsNone(result)
