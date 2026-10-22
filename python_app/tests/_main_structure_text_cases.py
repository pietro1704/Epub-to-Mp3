"""Structure Text regression scenarios, collected by test_main."""

from python_app.tests._main_test_support import Chapter as Chapter
from python_app.tests._main_test_support import ConverterApplication as ConverterApplication
from python_app.tests._main_test_support import Mock as Mock
from python_app.tests._main_test_support import patch as patch
from python_app.tests._main_test_support import unittest as unittest


class TestSectionNumberDisplay(unittest.TestCase):
    """Tests for section-number post-processing in _generate_structure_items.

    When multiple chapters share the same TOC-derived index (e.g. all have
    index "5.1"), the post-processing pass renames them to "5.1.1", "5.1.2",
    "5.1.3" and also appends the section number to sub_title and rebuilds
    display_name to include the section number as visible text.
    """

    def setUp(self):
        self.app = ConverterApplication()

    def _make_chapter(
        self, source_path: str, name: str = "Chapter", text: str = "Text body"
    ) -> Chapter:
        """Create a minimal Chapter for testing."""
        return Chapter(
            index=1,
            name=name,
            source_path=source_path,
            text=text,
        )

    def _make_mock_reader(self, chapters):
        """Build a mock EbookReader with no TOC (pure fallback path bypassed)."""
        reader = Mock()
        reader.title = "Test Book"
        reader.author = "Test Author"
        reader.get_chapters.return_value = chapters
        # No TOC entries
        reader.get_toc.return_value = []
        return reader

    def _make_toc_outline_entry(self, path_indices, title="Chapter 5", sub_title="Section 1"):
        """Build a single TOC outline entry as returned by _build_toc_outline_map."""
        return {
            "path_indices": list(path_indices),
            "path_titles": [title, sub_title],
            "title": sub_title,
        }

    def _run_with_shared_index(
        self, n_chapters: int, shared_index=(5, 1), sub_title="Ben Hanscom sofre uma queda"
    ):
        """Run _generate_structure_items with n_chapters all sharing the same TOC index."""
        source_path = "oebps/chapter5.html"
        chapters = [
            self._make_chapter(source_path, f"Chapter {i+1}", f"Body text for section {i+1}.")
            for i in range(n_chapters)
        ]
        reader = self._make_mock_reader(chapters)

        toc_outline_entry = self._make_toc_outline_entry(shared_index, "Chapter 5", sub_title)

        with (
            patch.object(self.app, "_build_toc_map", return_value={}),
            patch.object(
                self.app,
                "_build_toc_outline_map",
                return_value={"oebps/chapter5.html": [toc_outline_entry]},
            ),
        ):
            items = self.app._generate_structure_items(reader, filter_chapters=False)

        return items

    def test_three_shared_index_chapters_get_section_suffix_in_display_name(self):
        """When 3 chapters share the same TOC index, display_names include '- 1', '- 2', '- 3'."""
        items = self._run_with_shared_index(3)
        self.assertEqual(len(items), 3)
        for i, item in enumerate(items, 1):
            self.assertIn(
                f"- {i}",
                item.display_name,
                f"display_name '{item.display_name}' should contain '- {i}'",
            )

    def test_three_shared_index_chapters_get_unique_numeric_indices(self):
        """When 3 chapters share the same TOC index '5.1', they become '5.1.1', '5.1.2', '5.1.3'."""
        items = self._run_with_shared_index(3)
        self.assertEqual(len(items), 3)
        expected_indices = ["5.1.1", "5.1.2", "5.1.3"]
        for item, expected in zip(items, expected_indices):
            self.assertEqual(
                item.index, expected, f"Expected index '{expected}', got '{item.index}'"
            )

    def test_three_shared_index_chapters_sub_title_includes_section_number(self):
        """sub_title must be updated to include the section number suffix."""
        sub_title = "Ben Hanscom sofre uma queda"
        items = self._run_with_shared_index(3, sub_title=sub_title)
        self.assertEqual(len(items), 3)
        for i, item in enumerate(items, 1):
            self.assertIsNotNone(item.sub_title, f"sub_title should not be None for item {i}")
            self.assertIn(
                str(i),
                item.sub_title,
                f"sub_title '{item.sub_title}' should contain section number {i}",
            )

    def test_single_chapter_unique_index_is_unaffected(self):
        """A chapter with a unique index is not modified by the post-processing pass."""
        source_path = "oebps/chapter3.html"
        chapters = [self._make_chapter(source_path, "Chapter 3", "Unique body text.")]
        reader = self._make_mock_reader(chapters)
        toc_outline_entry = self._make_toc_outline_entry((3, 1), "Chapter 3", "Only section")

        with (
            patch.object(self.app, "_build_toc_map", return_value={}),
            patch.object(
                self.app,
                "_build_toc_outline_map",
                return_value={"oebps/chapter3.html": [toc_outline_entry]},
            ),
        ):
            items = self.app._generate_structure_items(reader, filter_chapters=False)

        self.assertEqual(len(items), 1)
        item = items[0]
        # Index must NOT have an extra ".1" suffix appended
        self.assertEqual(item.index, "3.1")
        # display_name must NOT end with "- 1"
        self.assertFalse(
            item.display_name.endswith("- 1"),
            f"Single-chapter display_name '{item.display_name}' should not have '- 1' appended",
        )

    def test_display_name_section_number_is_in_text_part_not_only_numeric_prefix(self):
        """Section number appears in the text body of display_name, not only in the numeric prefix."""
        items = self._run_with_shared_index(2)
        self.assertEqual(len(items), 2)
        for i, item in enumerate(items, 1):
            # The numeric prefix is e.g. "5.1.1"; the text part must also contain "- 1"
            text_part = item.display_name[len(item.index) :]
            self.assertIn(
                f"- {i}",
                text_part,
                f"Section number '- {i}' should appear in text part of display_name, "
                f"got: '{item.display_name}'",
            )


class TestPrepareChapterTextHeadingDedup(unittest.TestCase):
    """Regression tests for _prepare_chapter_text heading deduplication.

    Bug: _heading_contains used substring matching without word-count guards.
    A short section title like "Quarto de Eddie" was dropped when followed by
    body text that naturally contained the phrase (e.g. "subiram para o quarto
    de Eddie"), because the body was seen as "more descriptive".

    Fix: deduplication only applies when BOTH lines are short (<=8 words).
    """

    def setUp(self):
        self.app = ConverterApplication()

    def test_short_section_title_not_dropped_when_body_contains_phrase(self):
        """'Quarto de Eddie' must survive when body text contains 'quarto de Eddie'."""
        text = (
            "3\nQuarto de Eddie\n"
            "Beverly e Bill se vestiram rapidamente, sem falar, e subiram para o quarto de Eddie."
        )
        label = (
            "8.2.3 - Parte 5 – O ritual de Chüd - Capítulo 20 – O círculo se fecha"
            " - 3 quarto de eddie beverly e bill"
        )
        result = self.app._prepare_chapter_text(text, display_name=label, book_title="It: A coisa")
        self.assertIn("Quarto de Eddie", result)
        self.assertIn("Beverly e Bill se vestiram", result)

    def test_section_number_preserved_before_title(self):
        """Section number '3' must appear before 'Quarto de Eddie' in output."""
        text = (
            "3\nQuarto de Eddie\n"
            "Beverly e Bill se vestiram rapidamente, sem falar, e subiram para o quarto de Eddie."
        )
        label = "8.2.3 - Capítulo 20 – O círculo se fecha - 3 quarto de eddie"
        result = self.app._prepare_chapter_text(text, display_name=label, book_title="It: A coisa")
        idx_3 = result.find("3")
        idx_title = result.find("Quarto de Eddie")
        self.assertLess(idx_3, idx_title, "'3' must appear before 'Quarto de Eddie'")

    def test_true_duplicate_heading_still_deduplicated(self):
        """Actual duplicate headings (same short string twice) are still removed."""
        text = "Capítulo 20\nCapítulo 20\nBody text here."
        label = "8.2 - Capítulo 20 body text"
        result = self.app._prepare_chapter_text(text, display_name=label, book_title="It")
        self.assertEqual(result.count("Capítulo 20"), 1, "duplicate heading must be removed")

    def test_longer_heading_replaces_shorter_duplicate(self):
        """When two short headings overlap, the more descriptive one is kept."""
        text = "Seção\nSeção 1\nBody."
        label = "1.1 - secao 1"
        result = self.app._prepare_chapter_text(text, display_name=label, book_title="Book")
        self.assertIn("Seção 1", result)
