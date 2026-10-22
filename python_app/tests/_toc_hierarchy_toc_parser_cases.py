"""Toc Parser regression scenarios, collected by test_toc_hierarchy."""

from python_app.tests._toc_hierarchy_test_support import (
    EpubParser as EpubParser,
    TocItem as TocItem,
    _nav_xhtml as _nav_xhtml,
    unittest as unittest,
)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestBuildTocLevelMap(unittest.TestCase):
    """Unit tests for EpubParser._build_toc_level_map."""

    def test_empty_toc(self):
        result = EpubParser._build_toc_level_map([])
        self.assertEqual(result, {})

    def test_flat_toc(self):
        toc = [
            TocItem("Ch 1", "ch1.xhtml", level=1),
            TocItem("Ch 2", "ch2.xhtml", level=1),
            TocItem("Ch 3", "ch3.xhtml", level=1),
        ]
        result = EpubParser._build_toc_level_map(toc)
        self.assertEqual(result, {"ch1.xhtml": 1, "ch2.xhtml": 1, "ch3.xhtml": 1})

    def test_two_level_toc(self):
        toc = [
            TocItem(
                "Part 1",
                "part1.xhtml",
                level=1,
                children=[
                    TocItem("Ch 1", "ch1.xhtml", level=2),
                    TocItem("Ch 2", "ch2.xhtml", level=2),
                ],
            ),
            TocItem(
                "Part 2",
                "part2.xhtml",
                level=1,
                children=[
                    TocItem("Ch 3", "ch3.xhtml", level=2),
                ],
            ),
        ]
        result = EpubParser._build_toc_level_map(toc)
        self.assertEqual(result["part1.xhtml"], 1)
        self.assertEqual(result["part2.xhtml"], 1)
        self.assertEqual(result["ch1.xhtml"], 2)
        self.assertEqual(result["ch2.xhtml"], 2)
        self.assertEqual(result["ch3.xhtml"], 2)

    def test_three_level_toc(self):
        toc = [
            TocItem(
                "Vol 1",
                "vol1.xhtml",
                level=1,
                children=[
                    TocItem(
                        "Book 1",
                        "book1.xhtml",
                        level=2,
                        children=[
                            TocItem("Ch 1", "ch1.xhtml", level=3),
                            TocItem("Ch 2", "ch2.xhtml", level=3),
                        ],
                    ),
                ],
            ),
        ]
        result = EpubParser._build_toc_level_map(toc)
        self.assertEqual(result["vol1.xhtml"], 1)
        self.assertEqual(result["book1.xhtml"], 2)
        self.assertEqual(result["ch1.xhtml"], 3)
        self.assertEqual(result["ch2.xhtml"], 3)

    def test_anchor_only_subchapters_keep_parent_file_at_min_level(self):
        """When a file is referenced at L1 AND at L2 (via anchor), it stays at L1."""
        toc = [
            TocItem(
                "Section I",
                "sec1.xhtml#top",
                level=1,
                children=[
                    TocItem("1.1", "sec1.xhtml#heading1", level=2),
                    TocItem("1.2", "sec1.xhtml#heading2", level=2),
                ],
            ),
            TocItem("Section II", "sec2.xhtml", level=1),
        ]
        result = EpubParser._build_toc_level_map(toc)
        # sec1.xhtml is referenced at L1 (with anchor) and L2 (with anchor).
        # Minimum is 1.
        self.assertEqual(result["sec1.xhtml"], 1)
        self.assertEqual(result["sec2.xhtml"], 1)

    def test_href_without_anchor_and_with_anchor_share_same_file(self):
        """Anchor-stripped key means #anchor variants all map to the bare filename."""
        toc = [
            TocItem(
                "Ch 1",
                "ch1.xhtml",
                level=1,
                children=[
                    TocItem("Sec 1", "ch1.xhtml#s1", level=2),
                ],
            ),
        ]
        result = EpubParser._build_toc_level_map(toc)
        self.assertEqual(result.get("ch1.xhtml"), 1)
        # Anchor form should NOT create a separate key
        self.assertNotIn("ch1.xhtml#s1", result)

    def test_split_files_get_correct_levels(self):
        """Each split file can have an independent TOC level."""
        toc = [
            TocItem(
                "Part 1",
                "part_split_000.xhtml",
                level=1,
                children=[
                    TocItem("Sec A", "part_split_001.xhtml", level=2),
                    TocItem("Sec B", "part_split_002.xhtml", level=2),
                ],
            ),
        ]
        result = EpubParser._build_toc_level_map(toc)
        self.assertEqual(result["part_split_000.xhtml"], 1)
        self.assertEqual(result["part_split_001.xhtml"], 2)
        self.assertEqual(result["part_split_002.xhtml"], 2)


class TestParseNavHtml(unittest.TestCase):
    """Unit tests for EpubParser._parse_nav_html."""

    def test_flat_nav(self):
        nav = _nav_xhtml("""
            <li><a href="ch1.xhtml">Chapter 1</a></li>
            <li><a href="ch2.xhtml">Chapter 2</a></li>
        """)
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0].title, "Chapter 1")
        self.assertEqual(items[0].href, "ch1.xhtml")
        self.assertEqual(items[0].level, 1)
        self.assertEqual(items[1].title, "Chapter 2")
        self.assertEqual(items[1].level, 1)

    def test_nested_nav(self):
        nav = _nav_xhtml("""
            <li><a href="part1.xhtml">Part 1</a>
              <ol>
                <li><a href="ch1.xhtml">Chapter 1</a></li>
                <li><a href="ch2.xhtml">Chapter 2</a></li>
              </ol>
            </li>
            <li><a href="part2.xhtml">Part 2</a>
              <ol>
                <li><a href="ch3.xhtml">Chapter 3</a></li>
              </ol>
            </li>
        """)
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0].level, 1)
        self.assertEqual(items[0].title, "Part 1")
        self.assertEqual(len(items[0].children), 2)
        self.assertEqual(items[0].children[0].level, 2)
        self.assertEqual(items[0].children[0].title, "Chapter 1")
        self.assertEqual(items[1].level, 1)
        self.assertEqual(len(items[1].children), 1)
        self.assertEqual(items[1].children[0].title, "Chapter 3")

    def test_three_level_nav(self):
        nav = _nav_xhtml("""
            <li><a href="vol1.xhtml">Volume 1</a>
              <ol>
                <li><a href="book1.xhtml">Book 1</a>
                  <ol>
                    <li><a href="ch1.xhtml">Chapter 1</a></li>
                  </ol>
                </li>
              </ol>
            </li>
        """)
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(items[0].level, 1)
        self.assertEqual(items[0].children[0].level, 2)
        self.assertEqual(items[0].children[0].children[0].level, 3)

    def test_nav_without_toc_type_returns_empty(self):
        nav = """<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
<body>
<nav epub:type="landmarks">
  <ol><li><a href="ch1.xhtml">Chapter 1</a></li></ol>
</nav>
</body></html>"""
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(items, [])

    def test_malformed_xml_returns_empty(self):
        items = EpubParser._parse_nav_html("<<not valid xml>>")
        self.assertEqual(items, [])

    def test_empty_string_returns_empty(self):
        items = EpubParser._parse_nav_html("")
        self.assertEqual(items, [])

    def test_href_with_anchor(self):
        nav = _nav_xhtml("""
            <li><a href="ch1.xhtml">Ch 1</a>
              <ol>
                <li><a href="ch1.xhtml#section1">Section 1</a></li>
              </ol>
            </li>
        """)
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(items[0].href, "ch1.xhtml")
        self.assertEqual(items[0].children[0].href, "ch1.xhtml#section1")


class TestParseNavHtmlEdgeCases(unittest.TestCase):
    """Additional edge cases for _parse_nav_html."""

    def test_span_instead_of_a(self):
        """<span> used as heading placeholder (no href); item should still be created with title."""
        nav = _nav_xhtml("""
            <li><span>Part One</span>
              <ol>
                <li><a href="ch1.xhtml">Chapter 1</a></li>
              </ol>
            </li>
        """)
        items = EpubParser._parse_nav_html(nav)
        # The span-only li has title but empty href; children should be nested
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].title, "Part One")
        self.assertEqual(items[0].href, "")
        self.assertEqual(len(items[0].children), 1)
        self.assertEqual(items[0].children[0].title, "Chapter 1")
        self.assertEqual(items[0].children[0].level, 2)

    def test_landmarks_and_toc_nav_toc_wins(self):
        """When document has both landmarks and toc <nav>, the toc nav is used."""
        nav = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>nav</title></head>
<body>
<nav epub:type="landmarks">
  <ol>
    <li><a href="text.xhtml#start">Begin Reading</a></li>
  </ol>
</nav>
<nav epub:type="toc">
  <ol>
    <li><a href="ch1.xhtml">Chapter 1</a></li>
    <li><a href="ch2.xhtml">Chapter 2</a></li>
  </ol>
</nav>
</body></html>"""
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0].href, "ch1.xhtml")
        self.assertEqual(items[1].href, "ch2.xhtml")

    def test_li_with_no_a_and_no_span_is_skipped(self):
        """<li> with only a <p> child (neither <a> nor <span>) should be skipped."""
        nav = _nav_xhtml("""
            <li><p>Not a link</p></li>
            <li><a href="ch1.xhtml">Chapter 1</a></li>
        """)
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].href, "ch1.xhtml")

    def test_nested_only_items_no_top_anchor(self):
        """Top li has no anchor, only a nested ol. Children are still parsed."""
        nav = _nav_xhtml("""
            <li><span>Untitled Part</span>
              <ol>
                <li><a href="ch1.xhtml">Chapter 1</a></li>
                <li><a href="ch2.xhtml">Chapter 2</a></li>
                <li><a href="ch3.xhtml">Chapter 3</a></li>
              </ol>
            </li>
        """)
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(len(items), 1)
        self.assertEqual(len(items[0].children), 3)
        for child in items[0].children:
            self.assertEqual(child.level, 2)

    def test_whitespace_in_title(self):
        """Nav titles with surrounding whitespace and newlines are stripped."""
        nav = _nav_xhtml("""
            <li><a href="ch1.xhtml">
                Chapter  1
            </a></li>
        """)
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].title, "Chapter  1")

    def test_four_level_nav(self):
        """4-level hierarchy: Vol > Book > Part > Chapter."""
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
        items = EpubParser._parse_nav_html(nav)
        self.assertEqual(items[0].level, 1)
        self.assertEqual(items[0].children[0].level, 2)
        self.assertEqual(items[0].children[0].children[0].level, 3)
        self.assertEqual(items[0].children[0].children[0].children[0].level, 4)
        self.assertEqual(items[0].children[0].children[0].children[0].href, "ch1.xhtml")


class TestBuildTocLevelMapEdgeCases(unittest.TestCase):
    """Additional edge cases for _build_toc_level_map."""

    def test_items_with_empty_href_are_ignored(self):
        """TocItems with empty href (span-only nav entries) must not create map keys."""
        toc = [
            TocItem(
                "Part One",
                "",
                level=1,
                children=[
                    TocItem("Ch 1", "ch1.xhtml", level=2),
                ],
            ),
        ]
        result = EpubParser._build_toc_level_map(toc)
        self.assertNotIn("", result)
        self.assertEqual(result.get("ch1.xhtml"), 2)

    def test_same_file_at_three_depths_keeps_minimum(self):
        """File referenced at L1, L2, and L3 → map value is 1."""
        toc = [
            TocItem(
                "Top",
                "shared.xhtml#top",
                level=1,
                children=[
                    TocItem(
                        "Mid",
                        "shared.xhtml#mid",
                        level=2,
                        children=[
                            TocItem("Deep", "shared.xhtml#deep", level=3),
                        ],
                    ),
                ],
            ),
        ]
        result = EpubParser._build_toc_level_map(toc)
        self.assertEqual(result.get("shared.xhtml"), 1)
