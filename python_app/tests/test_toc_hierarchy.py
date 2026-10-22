# -*- coding: utf-8 -*-
"""
Unit tests for TOC hierarchy parsing and chapter level detection.

Covers:
- NCX-based TOC parsing (EPUB2) with flat and nested structures
- EPUB3 nav.xhtml fallback parsing
- Level assignment from TOC to spine chapters
- Anchor-only subchapters (same file referenced at multiple TOC depths)
- Split-file handling (_split_000, _split_001, ...)
- Three-level deep hierarchies (e.g. Volume > Book > Chapter)
- Files not referenced by TOC default to level 1
- _build_toc_level_map and _parse_nav_html unit tests
"""

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from python_app.tests._toc_hierarchy_test_support import (
    EpubBuilder as EpubBuilder,
    EpubParser as EpubParser,
    _container_xml as _container_xml,
    _nav_point as _nav_point,
    _nav_xhtml as _nav_xhtml,
    _ncx as _ncx,
    _opf as _opf,
    _xhtml as _xhtml,
    os as os,
    tempfile as tempfile,
    unittest as unittest,
)

from python_app.tests._toc_hierarchy_toc_parser_cases import (
    TestBuildTocLevelMap as TestBuildTocLevelMap,
    TestParseNavHtml as TestParseNavHtml,
    TestParseNavHtmlEdgeCases as TestParseNavHtmlEdgeCases,
    TestBuildTocLevelMapEdgeCases as TestBuildTocLevelMapEdgeCases,
)
from python_app.tests._toc_hierarchy_navigation_fallback_cases import (
    TestEpub3NavFallback as TestEpub3NavFallback,
    TestFilesNotInToc as TestFilesNotInToc,
    TestItAcoisaSimulation as TestItAcoisaSimulation,
    TestNcxFallbackToNav as TestNcxFallbackToNav,
    TestParseNavTocFromOpf as TestParseNavTocFromOpf,
)
from python_app.tests._toc_hierarchy_structure_indices_cases import (
    TestGenerateStructureItemsIndices as TestGenerateStructureItemsIndices,
)

class TestFlatEpub(unittest.TestCase):
    """A book with no TOC hierarchy: all chapters should have level=1."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_flat_ncx(self):
        ncx = _ncx(
            _nav_point("p1", "Chapter 1", "ch1.xhtml")
            + _nav_point("p2", "Chapter 2", "ch2.xhtml")
            + _nav_point("p3", "Chapter 3", "ch3.xhtml")
        )
        (
            EpubBuilder()
            .add_spine_file("ch1", "<p>One.</p>")
            .add_spine_file("ch2", "<p>Two.</p>")
            .add_spine_file("ch3", "<p>Three.</p>")
            .set_ncx(ncx)
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 3)
        for ch in book.chapters:
            self.assertEqual(ch.level, 1, f"Expected level 1 for '{ch.name}'")

    def test_flat_nav_xhtml_no_ncx(self):
        nav = _nav_xhtml("""
            <li><a href="ch1.xhtml">Chapter 1</a></li>
            <li><a href="ch2.xhtml">Chapter 2</a></li>
        """)
        (
            EpubBuilder()
            .add_spine_file("ch1", "<p>One.</p>")
            .add_spine_file("ch2", "<p>Two.</p>")
            .set_nav(nav)
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 2)
        for ch in book.chapters:
            self.assertEqual(ch.level, 1, f"Expected level 1 for '{ch.name}'")


class TestTwoLevelEpub(unittest.TestCase):
    """Books with Part (L1) > Chapter (L2) structure."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def _build(self, use_nav=False):
        if use_nav:
            nav = _nav_xhtml("""
                <li><a href="part1.xhtml">Part 1</a>
                  <ol>
                    <li><a href="ch1.xhtml">Chapter 1</a></li>
                    <li><a href="ch2.xhtml">Chapter 2</a></li>
                    <li><a href="ch3.xhtml">Chapter 3</a></li>
                  </ol>
                </li>
                <li><a href="part2.xhtml">Part 2</a>
                  <ol>
                    <li><a href="ch4.xhtml">Chapter 4</a></li>
                  </ol>
                </li>
            """)
            builder = EpubBuilder().set_nav(nav)
        else:
            ncx = _ncx(
                _nav_point(
                    "part1",
                    "Part 1",
                    "part1.xhtml",
                    children=(
                        _nav_point("c1", "Chapter 1", "ch1.xhtml")
                        + _nav_point("c2", "Chapter 2", "ch2.xhtml")
                        + _nav_point("c3", "Chapter 3", "ch3.xhtml")
                    ),
                )
                + _nav_point(
                    "part2",
                    "Part 2",
                    "part2.xhtml",
                    children=_nav_point("c4", "Chapter 4", "ch4.xhtml"),
                )
            )
            builder = EpubBuilder().set_ncx(ncx)

        (
            builder.add_spine_file("part1", "<h1>Part 1</h1>")
            .add_spine_file("ch1", "<h2>Chapter 1</h2><p>Content 1.</p>")
            .add_spine_file("ch2", "<h2>Chapter 2</h2><p>Content 2.</p>")
            .add_spine_file("ch3", "<h2>Chapter 3</h2><p>Content 3.</p>")
            .add_spine_file("part2", "<h1>Part 2</h1>")
            .add_spine_file("ch4", "<h2>Chapter 4</h2><p>Content 4.</p>")
            .write(self.tmp)
        )

    def test_ncx_levels(self):
        self._build(use_nav=False)
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 6)
        levels = [ch.level for ch in book.chapters]
        self.assertEqual(levels, [1, 2, 2, 2, 1, 2])

    def test_nav_xhtml_levels(self):
        self._build(use_nav=True)
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 6)
        levels = [ch.level for ch in book.chapters]
        self.assertEqual(levels, [1, 2, 2, 2, 1, 2])

    def test_toc_item_count(self):
        self._build(use_nav=False)
        book = EpubParser(self.tmp).parse()
        # Two top-level items in TOC
        self.assertEqual(len(book.toc), 2)
        self.assertEqual(book.toc[0].level, 1)
        self.assertEqual(len(book.toc[0].children), 3)
        self.assertEqual(book.toc[0].children[0].level, 2)

    def test_chapter_names_preserved(self):
        self._build(use_nav=False)
        book = EpubParser(self.tmp).parse()
        names = [ch.name for ch in book.chapters]
        # TOC titles are used as chapter names for TOC-matched chapters
        self.assertTrue(any("Part 1" in n or "Part" in n for n in names))

    def test_it_structure_simulation(self):
        """Simulates IT (A coisa) structure: 5 Parts each with chapters."""
        ncx_parts = ""
        for p in range(1, 4):
            ch_points = "".join(
                _nav_point(f"c{p}_{c}", f"Chapter {p}.{c}", f"ch{p}_{c}.xhtml") for c in range(1, 4)
            )
            ncx_parts += _nav_point(f"part{p}", f"Part {p}", f"part{p}.xhtml", children=ch_points)

        ncx = _ncx(ncx_parts)
        builder = EpubBuilder().set_ncx(ncx)
        for p in range(1, 4):
            builder.add_spine_file(f"part{p}", f"<h1>Part {p}</h1>")
            for c in range(1, 4):
                builder.add_spine_file(f"ch{p}_{c}", f"<h2>Chapter {p}.{c}</h2><p>Text.</p>")
        builder.write(self.tmp)

        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 12)  # 3 parts + 9 chapters

        part_chapters = [ch for ch in book.chapters if ch.level == 1]
        sub_chapters = [ch for ch in book.chapters if ch.level == 2]
        self.assertEqual(len(part_chapters), 3)
        self.assertEqual(len(sub_chapters), 9)


class TestThreeLevelEpub(unittest.TestCase):
    """Books with Volume (L1) > Book (L2) > Chapter (L3) structure (e.g. Dom Quixote)."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_three_levels_ncx(self):
        ncx = _ncx(
            _nav_point(
                "vol1",
                "Volume I",
                "vol1.xhtml",
                children=_nav_point(
                    "book1",
                    "Book I",
                    "book1.xhtml",
                    children=(
                        _nav_point("ch1", "Chapter I", "ch1.xhtml")
                        + _nav_point("ch2", "Chapter II", "ch2.xhtml")
                    ),
                ),
            )
            + _nav_point(
                "vol2",
                "Volume II",
                "vol2.xhtml",
                children=_nav_point(
                    "book2",
                    "Book II",
                    "book2.xhtml",
                    children=_nav_point("ch3", "Chapter III", "ch3.xhtml"),
                ),
            )
        )
        (
            EpubBuilder()
            .set_ncx(ncx)
            .add_spine_file("vol1", "<h1>Volume I</h1>")
            .add_spine_file("book1", "<h2>Book I</h2>")
            .add_spine_file("ch1", "<h3>Chapter I</h3><p>Text.</p>")
            .add_spine_file("ch2", "<h3>Chapter II</h3><p>Text.</p>")
            .add_spine_file("vol2", "<h1>Volume II</h1>")
            .add_spine_file("book2", "<h2>Book II</h2>")
            .add_spine_file("ch3", "<h3>Chapter III</h3><p>Text.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 7)
        levels = [ch.level for ch in book.chapters]
        self.assertEqual(levels, [1, 2, 3, 3, 1, 2, 3])

    def test_three_levels_nav_xhtml(self):
        nav = _nav_xhtml("""
            <li><a href="vol1.xhtml">Volume I</a>
              <ol>
                <li><a href="book1.xhtml">Book I</a>
                  <ol>
                    <li><a href="ch1.xhtml">Chapter I</a></li>
                  </ol>
                </li>
              </ol>
            </li>
        """)
        (
            EpubBuilder()
            .set_nav(nav)
            .add_spine_file("vol1", "<h1>Volume I</h1>")
            .add_spine_file("book1", "<h2>Book I</h2>")
            .add_spine_file("ch1", "<h3>Chapter I</h3><p>Text.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 3)
        levels = [ch.level for ch in book.chapters]
        self.assertEqual(levels, [1, 2, 3])


class TestAnchorOnlySubchapters(unittest.TestCase):
    """Files with anchor-only TOC subchapters stay at their parent's level."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_same_file_anchors_keep_file_at_level1(self):
        """
        La paz interior style: L1 points to sec1.xhtml (with anchor),
        L2 points to sec1.xhtml#heading_1, sec1.xhtml#heading_2.
        The spine file sec1.xhtml should remain at level 1.
        """
        ncx = _ncx(
            _nav_point(
                "sec1",
                "Section I",
                "sec1.xhtml#top",
                children=(
                    _nav_point("s1a", "1.1 Subsection", "sec1.xhtml#h1")
                    + _nav_point("s1b", "1.2 Subsection", "sec1.xhtml#h2")
                ),
            )
            + _nav_point("sec2", "Section II", "sec2.xhtml")
        )
        (
            EpubBuilder()
            .set_ncx(ncx)
            .add_spine_file("sec1", "<h1>Section I</h1><h2>1.1</h2><h2>1.2</h2><p>Text.</p>")
            .add_spine_file("sec2", "<h1>Section II</h1><p>Text.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 2)
        # Both spine files are at level 1 (sec1 is the L1 entry even with anchor)
        self.assertEqual(book.chapters[0].level, 1)
        self.assertEqual(book.chapters[1].level, 1)

    def test_mixed_same_file_and_different_file_subchapters(self):
        """
        Montanha Mágica style: L1 is part_split_000 (with anchor),
        one L2 is same file (with anchor), other L2s are different split files.
        """
        ncx = _ncx(
            _nav_point(
                "chI",
                "Chapter I",
                "part_split_000.xhtml#top",
                children=(
                    _nav_point("s1", "Section A", "part_split_000.xhtml#secA")
                    + _nav_point("s2", "Section B", "part_split_001.xhtml")
                    + _nav_point("s3", "Section C", "part_split_002.xhtml")
                ),
            )
        )
        (
            EpubBuilder()
            .set_ncx(ncx)
            .add_spine_file("part_split_000", "<h1>Chapter I</h1><h2>Section A</h2><p>A.</p>")
            .add_spine_file("part_split_001", "<h2>Section B</h2><p>B.</p>")
            .add_spine_file("part_split_002", "<h2>Section C</h2><p>C.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 3)
        # part_split_000 → L1 (appears as L1 TOC entry with anchor)
        self.assertEqual(book.chapters[0].level, 1)
        # split_001 → L2, split_002 → L2
        self.assertEqual(book.chapters[1].level, 2)
        self.assertEqual(book.chapters[2].level, 2)


class TestFourLevelEpub(unittest.TestCase):
    """4-level EPUB: Volume > Book > Part > Chapter."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_four_levels_ncx(self):
        ncx = _ncx(
            _nav_point(
                "vol1",
                "Volume I",
                "vol1.xhtml",
                children=_nav_point(
                    "book1",
                    "Book I",
                    "book1.xhtml",
                    children=_nav_point(
                        "part1",
                        "Part I",
                        "part1.xhtml",
                        children=(
                            _nav_point("ch1", "Chapter 1", "ch1.xhtml")
                            + _nav_point("ch2", "Chapter 2", "ch2.xhtml")
                        ),
                    ),
                ),
            )
        )
        (
            EpubBuilder()
            .set_ncx(ncx)
            .add_spine_file("vol1", "<h1>Volume I</h1>")
            .add_spine_file("book1", "<h2>Book I</h2>")
            .add_spine_file("part1", "<h3>Part I</h3>")
            .add_spine_file("ch1", "<h4>Chapter 1</h4><p>Text.</p>")
            .add_spine_file("ch2", "<h4>Chapter 2</h4><p>Text.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 5)
        levels = [ch.level for ch in book.chapters]
        self.assertEqual(levels, [1, 2, 3, 4, 4])

    def test_four_levels_nav_xhtml(self):
        nav = _nav_xhtml("""
            <li><a href="vol1.xhtml">Volume I</a>
              <ol>
                <li><a href="book1.xhtml">Book I</a>
                  <ol>
                    <li><a href="part1.xhtml">Part I</a>
                      <ol>
                        <li><a href="ch1.xhtml">Chapter 1</a></li>
                      </ol>
                    </li>
                  </ol>
                </li>
              </ol>
            </li>
        """)
        (
            EpubBuilder()
            .set_nav(nav)
            .add_spine_file("vol1", "<h1>Volume I</h1>")
            .add_spine_file("book1", "<h2>Book I</h2>")
            .add_spine_file("part1", "<h3>Part I</h3>")
            .add_spine_file("ch1", "<h4>Chapter 1</h4><p>Text.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        levels = [ch.level for ch in book.chapters]
        self.assertEqual(levels, [1, 2, 3, 4])


if __name__ == "__main__":
    unittest.main()
