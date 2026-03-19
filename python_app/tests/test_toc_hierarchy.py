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

import os
import tempfile
import unittest
import zipfile

from src.ebook_reader import EpubParser, TocItem

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _container_xml(opf_path="OEBPS/content.opf"):
    return f"""<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
        <rootfile full-path="{opf_path}"
                  media-type="application/oebps-package+xml"/>
    </rootfiles>
</container>"""


def _opf(spine_ids, manifest_extra="", version="2.0", metadata_extra=""):
    items = "\n".join(
        f'<item id="{sid}" href="{sid}.xhtml" media-type="application/xhtml+xml"/>'
        for sid in spine_ids
    )
    spine = "\n".join(f'<itemref idref="{sid}"/>' for sid in spine_ids)
    return f"""<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="{version}">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Test Book</dc:title>
        <dc:creator>Test Author</dc:creator>
        <dc:language>en</dc:language>
        {metadata_extra}
    </metadata>
    <manifest>
        {items}
        {manifest_extra}
    </manifest>
    <spine>{spine}</spine>
</package>"""


def _ncx(nav_points_xml):
    return f"""<?xml version="1.0"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
    "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
    <head><meta name="dtb:uid" content="uid"/></head>
    <docTitle><text>Test Book</text></docTitle>
    <navMap>
        {nav_points_xml}
    </navMap>
</ncx>"""


def _nav_point(pid, title, href, children=""):
    return f"""<navPoint id="{pid}">
    <navLabel><text>{title}</text></navLabel>
    <content src="{href}"/>
    {children}
</navPoint>"""


def _xhtml(body="<p>Content.</p>"):
    return f"""<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title/></head>
<body>{body}</body>
</html>"""


def _nav_xhtml(ol_content):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>nav</title></head>
<body>
<nav epub:type="toc">
  <ol>
    {ol_content}
  </ol>
</nav>
</body>
</html>"""


class EpubBuilder:
    """Fluent builder for synthetic EPUBs used in tests."""

    def __init__(self):
        self._spine = []  # list of (id, html_content)
        self._ncx = None
        self._nav = None  # (href_in_oebps, content)
        self._base = "OEBPS"

    def add_spine_file(self, file_id, content="<p>Text.</p>"):
        self._spine.append((file_id, content))
        return self

    def set_ncx(self, ncx_content):
        self._ncx = ncx_content
        return self

    def set_nav(self, nav_content, href="nav.xhtml"):
        self._nav = (href, nav_content)
        return self

    def write(self, path):
        spine_ids = [sid for sid, _ in self._spine]

        nav_manifest = ""
        if self._nav:
            nav_href, _ = self._nav
            nav_manifest = (
                f'<item id="nav" href="{nav_href}" '
                f'media-type="application/xhtml+xml" properties="nav"/>'
            )

        version = "3.0" if (self._nav and not self._ncx) else "2.0"
        opf_content = _opf(spine_ids, manifest_extra=nav_manifest, version=version)

        with zipfile.ZipFile(path, "w") as zf:
            zf.writestr("META-INF/container.xml", _container_xml())
            zf.writestr(f"{self._base}/content.opf", opf_content)

            for file_id, html_body in self._spine:
                zf.writestr(
                    f"{self._base}/{file_id}.xhtml",
                    _xhtml(html_body),
                )

            if self._ncx:
                zf.writestr(f"{self._base}/toc.ncx", self._ncx)

            if self._nav:
                nav_href, nav_content = self._nav
                zf.writestr(f"{self._base}/{nav_href}", nav_content)

        return path


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


class TestFlatEpub(unittest.TestCase):
    """A book with no TOC hierarchy: all chapters should have level=1."""

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".epub")

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
        self.tmp = tempfile.mktemp(suffix=".epub")

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
        self.tmp = tempfile.mktemp(suffix=".epub")

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
        self.tmp = tempfile.mktemp(suffix=".epub")

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


class TestFilesNotInToc(unittest.TestCase):
    """Spine files not referenced in the TOC keep their default level (1)."""

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".epub")

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_extra_spine_files_default_to_level1(self):
        """Cover, title page, and other unlisted files should be level 1."""
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=_nav_point("ch1", "Chapter 1", "ch1.xhtml"),
            )
        )
        (
            EpubBuilder()
            .set_ncx(ncx)
            # cover and title_page are in spine but NOT in TOC
            .add_spine_file("cover", "<p>Cover</p>")
            .add_spine_file("title_page", "<p>Title</p>")
            .add_spine_file("part1", "<h1>Part 1</h1>")
            .add_spine_file("ch1", "<h2>Chapter 1</h2><p>Text.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.chapters), 4)
        # cover and title_page: not in TOC → level 1 (default)
        self.assertEqual(book.chapters[0].level, 1)  # cover
        self.assertEqual(book.chapters[1].level, 1)  # title_page
        # TOC-mapped files
        self.assertEqual(book.chapters[2].level, 1)  # part1
        self.assertEqual(book.chapters[3].level, 2)  # ch1

    def test_empty_toc_all_chapters_level1(self):
        """When there is no TOC at all, all chapters stay at level 1."""
        (
            EpubBuilder()
            .add_spine_file("ch1", "<p>One.</p>")
            .add_spine_file("ch2", "<p>Two.</p>")
            # No NCX, no nav
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        for ch in book.chapters:
            self.assertEqual(ch.level, 1)


class TestEpub3NavFallback(unittest.TestCase):
    """EPUB3 books with nav.xhtml and no NCX file."""

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".epub")

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_epub3_two_level_hierarchy(self):
        nav = _nav_xhtml("""
            <li><a href="part1.xhtml">Part I</a>
              <ol>
                <li><a href="ch1.xhtml">Chapter 1</a></li>
                <li><a href="ch2.xhtml">Chapter 2</a></li>
              </ol>
            </li>
            <li><a href="part2.xhtml">Part II</a>
              <ol>
                <li><a href="ch3.xhtml">Chapter 3</a></li>
              </ol>
            </li>
        """)
        (
            EpubBuilder()
            .set_nav(nav)
            .add_spine_file("part1", "<h1>Part I</h1>")
            .add_spine_file("ch1", "<h2>Chapter 1</h2><p>Text.</p>")
            .add_spine_file("ch2", "<h2>Chapter 2</h2><p>Text.</p>")
            .add_spine_file("part2", "<h1>Part II</h1>")
            .add_spine_file("ch3", "<h2>Chapter 3</h2><p>Text.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        # TOC parsed from nav.xhtml
        self.assertEqual(len(book.toc), 2)
        self.assertEqual(book.toc[0].title, "Part I")
        self.assertEqual(book.toc[0].level, 1)
        self.assertEqual(book.toc[0].children[0].title, "Chapter 1")
        self.assertEqual(book.toc[0].children[0].level, 2)

        # Level assignment from nav.xhtml TOC
        self.assertEqual(len(book.chapters), 5)
        levels = [ch.level for ch in book.chapters]
        self.assertEqual(levels, [1, 2, 2, 1, 2])

    def test_epub3_flat_hierarchy(self):
        nav = _nav_xhtml("""
            <li><a href="ch1.xhtml">Chapter 1</a></li>
            <li><a href="ch2.xhtml">Chapter 2</a></li>
            <li><a href="ch3.xhtml">Chapter 3</a></li>
        """)
        (
            EpubBuilder()
            .set_nav(nav)
            .add_spine_file("ch1", "<p>One.</p>")
            .add_spine_file("ch2", "<p>Two.</p>")
            .add_spine_file("ch3", "<p>Three.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        for ch in book.chapters:
            self.assertEqual(ch.level, 1)

    def test_ncx_takes_priority_over_nav(self):
        """When both NCX and nav.xhtml exist, NCX is used."""
        ncx = _ncx(
            _nav_point(
                "p1",
                "Part 1 (NCX)",
                "ch1.xhtml",
                children=_nav_point("c1", "Chapter 1 (NCX)", "ch2.xhtml"),
            )
        )
        # nav says flat; NCX says hierarchical — NCX wins
        nav = _nav_xhtml("""
            <li><a href="ch1.xhtml">Chapter 1 (NAV)</a></li>
            <li><a href="ch2.xhtml">Chapter 2 (NAV)</a></li>
        """)
        (
            EpubBuilder()
            .set_ncx(ncx)
            .set_nav(nav)
            .add_spine_file("ch1", "<p>One.</p>")
            .add_spine_file("ch2", "<p>Two.</p>")
            .write(self.tmp)
        )
        book = EpubParser(self.tmp).parse()
        # NCX hierarchy: ch1=L1, ch2=L2
        self.assertEqual(book.chapters[0].level, 1)
        self.assertEqual(book.chapters[1].level, 2)
        # TOC titles come from NCX
        self.assertEqual(book.toc[0].title, "Part 1 (NCX)")


class TestItAcoisaSimulation(unittest.TestCase):
    """
    Simulate the exact TOC structure of IT (A coisa) by Stephen King:
    5 parts at L1, each with several chapters at L2, plus interlude files
    that are NOT directly in the TOC.
    """

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".epub")

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_parts_and_chapters(self):
        # Build NCX: 3 parts, each with 3 chapters + 1 interlude (L2)
        ncx_content = ""
        for p in range(1, 4):
            ch_ncx = "".join(
                _nav_point(f"ch{p}_{c}", f"Chapter {p}.{c}", f"ch{p}_{c}.xhtml")
                for c in range(1, 4)
            )
            ch_ncx += _nav_point(f"inter{p}", f"Derry: Interlude {p}", f"inter{p}.xhtml")
            ncx_content += _nav_point(f"part{p}", f"Part {p}", f"part{p}.xhtml", children=ch_ncx)

        ncx = _ncx(ncx_content)
        builder = EpubBuilder().set_ncx(ncx)

        spine_files = []
        for p in range(1, 4):
            builder.add_spine_file(f"part{p}", f"<h1>Part {p}</h1>")
            for c in range(1, 4):
                builder.add_spine_file(f"ch{p}_{c}", f"<h2>Chapter {p}.{c}</h2><p>Text.</p>")
            builder.add_spine_file(f"inter{p}", f"<p>Interlude {p} header.</p>")
            # Extra spine file not in TOC (the actual interlude body)
            builder.add_spine_file(
                f"inter{p}_body",
                f"<p>Interlude {p} full content here, much longer.</p>",
            )

        builder.write(self.tmp)

        book = EpubParser(self.tmp).parse()

        # 3 parts + (3 chapters + 1 interlude + 1 interlude_body) * 3 = 3 + 15 = 18
        total = len(book.chapters)
        self.assertEqual(total, 18)

        # Parts should be L1
        part_chapters = [
            ch for ch in book.chapters if "part" in ch.source_path and "inter" not in ch.source_path
        ]
        for ch in part_chapters:
            self.assertEqual(ch.level, 1, f"{ch.name} should be L1")

        # Numbered chapters should be L2
        num_chapters = [
            ch
            for ch in book.chapters
            if "ch" in ch.source_path.split("/")[-1] and "_" in ch.source_path.split("/")[-1]
        ]
        for ch in num_chapters:
            self.assertEqual(ch.level, 2, f"{ch.name} should be L2")

        # Interludes in TOC should be L2
        interlude_toc = [
            ch
            for ch in book.chapters
            if ch.source_path.split("/")[-1].startswith("inter") and "body" not in ch.source_path
        ]
        for ch in interlude_toc:
            self.assertEqual(ch.level, 2, f"{ch.name} should be L2 (in TOC)")

        # Interlude body files (not in TOC) should default to L1
        interlude_body = [ch for ch in book.chapters if "body" in ch.source_path]
        for ch in interlude_body:
            self.assertEqual(ch.level, 1, f"{ch.name} should be L1 (not in TOC)")


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


class TestFourLevelEpub(unittest.TestCase):
    """4-level EPUB: Volume > Book > Part > Chapter."""

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".epub")

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


class TestNcxFallbackToNav(unittest.TestCase):
    """When NCX is malformed/missing navMap, EPUB3 nav.xhtml fallback is used."""

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".epub")

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def _write_epub_with_broken_ncx(self, ncx_content, nav_content):
        nav = _nav_xhtml(nav_content)
        spine_ids = ["ch1", "ch2"]
        nav_manifest = (
            '<item id="nav" href="nav.xhtml" '
            'media-type="application/xhtml+xml" properties="nav"/>'
        )
        opf_content = _opf(spine_ids, manifest_extra=nav_manifest, version="3.0")
        with zipfile.ZipFile(self.tmp, "w") as zf:
            zf.writestr("META-INF/container.xml", _container_xml())
            zf.writestr("OEBPS/content.opf", opf_content)
            zf.writestr("OEBPS/toc.ncx", ncx_content)
            zf.writestr("OEBPS/nav.xhtml", nav)
            zf.writestr("OEBPS/ch1.xhtml", _xhtml("<h2>Ch 1</h2><p>Text.</p>"))
            zf.writestr("OEBPS/ch2.xhtml", _xhtml("<h2>Ch 2</h2><p>Text.</p>"))

    def test_malformed_ncx_falls_back_to_nav(self):
        """Completely malformed NCX XML triggers ParseError → falls back to nav.xhtml."""
        self._write_epub_with_broken_ncx(
            ncx_content="<<<not valid xml at all>>>",
            nav_content='<li><a href="ch1.xhtml">Ch 1</a></li>'
            '<li><a href="ch2.xhtml">Ch 2</a></li>',
        )
        book = EpubParser(self.tmp).parse()
        # Nav.xhtml flat hierarchy: both chapters level 1
        self.assertEqual(len(book.toc), 2)
        for ch in book.chapters:
            self.assertEqual(ch.level, 1)

    def test_ncx_without_navmap_falls_back_to_nav(self):
        """Valid NCX XML but missing <navMap> falls back to nav.xhtml hierarchy."""
        ncx_no_navmap = """<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="uid"/></head>
  <docTitle><text>Test</text></docTitle>
</ncx>"""
        nav_hierarchical = (
            '<li><a href="ch1.xhtml">Part</a>'
            '  <ol><li><a href="ch2.xhtml">Chapter</a></li></ol>'
            "</li>"
        )
        self._write_epub_with_broken_ncx(ncx_no_navmap, nav_hierarchical)
        book = EpubParser(self.tmp).parse()
        self.assertEqual(len(book.toc), 1)
        self.assertEqual(book.toc[0].level, 1)
        self.assertEqual(book.toc[0].children[0].level, 2)
        # ch1 = L1 (Part), ch2 = L2 (Chapter)
        levels = [ch.level for ch in book.chapters]
        self.assertEqual(levels, [1, 2])


class TestParseNavTocFromOpf(unittest.TestCase):
    """Unit tests for EpubParser._parse_nav_toc_from_opf edge cases."""

    def _make_zip(self, files: dict) -> zipfile.ZipFile:
        """Build an in-memory ZipFile from a dict of path→content."""
        import io

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            for path, content in files.items():
                zf.writestr(path, content)
        buf.seek(0)
        return zipfile.ZipFile(buf, "r")

    def test_no_nav_item_in_manifest_returns_empty(self):
        """OPF without a nav item in manifest returns empty list."""
        opf = _opf(["ch1"], version="3.0")  # no nav manifest item
        zf = self._make_zip({"OEBPS/content.opf": opf})
        result = EpubParser._parse_nav_toc_from_opf(zf, "OEBPS/content.opf", "OEBPS")
        self.assertEqual(result, [])

    def test_nav_file_missing_from_zip_returns_empty(self):
        """OPF declares nav.xhtml but file is absent from ZIP → empty list."""
        nav_manifest = (
            '<item id="nav" href="nav.xhtml" '
            'media-type="application/xhtml+xml" properties="nav"/>'
        )
        opf = _opf(["ch1"], manifest_extra=nav_manifest, version="3.0")
        zf = self._make_zip({"OEBPS/content.opf": opf})
        result = EpubParser._parse_nav_toc_from_opf(zf, "OEBPS/content.opf", "OEBPS")
        self.assertEqual(result, [])

    def test_malformed_opf_returns_empty(self):
        """Malformed OPF XML returns empty list without raising."""
        zf = self._make_zip({"OEBPS/content.opf": "<<<broken xml>>>"})
        result = EpubParser._parse_nav_toc_from_opf(zf, "OEBPS/content.opf", "OEBPS")
        self.assertEqual(result, [])

    def test_valid_opf_with_nav_returns_items(self):
        """OPF with nav item + valid nav.xhtml returns correct TocItems."""
        nav_manifest = (
            '<item id="nav" href="nav.xhtml" '
            'media-type="application/xhtml+xml" properties="nav"/>'
        )
        opf = _opf(["ch1", "ch2"], manifest_extra=nav_manifest, version="3.0")
        nav = _nav_xhtml(
            '<li><a href="ch1.xhtml">Ch 1</a></li>' '<li><a href="ch2.xhtml">Ch 2</a></li>'
        )
        zf = self._make_zip(
            {
                "OEBPS/content.opf": opf,
                "OEBPS/nav.xhtml": nav,
            }
        )
        result = EpubParser._parse_nav_toc_from_opf(zf, "OEBPS/content.opf", "OEBPS")
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0].title, "Ch 1")
        self.assertEqual(result[1].href, "ch2.xhtml")


class TestGenerateStructureItemsIndices(unittest.TestCase):
    """Tests for _generate_structure_items index assignment.

    Covers three behaviours:
    1. TOC hierarchy produces hierarchical indices (4.1, 4.2, 10.1, 12.5, …).
    2. Chapters split at paragraph/CSS boundaries get unique sub-indices (4.3.1, 4.3.2, …).
    3. Short single-part chapters keep their plain index unchanged (e.g. "11").
    """

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".epub")

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def _make_app_and_reader(self, epub_path):
        from src.ebook_reader import EbookReader

        from python_app.main import ConverterApplication

        app = ConverterApplication()
        app._interactive_mode = False
        reader = EbookReader(epub_path)
        return app, reader

    # ------------------------------------------------------------------
    # Point 1: TOC hierarchy → hierarchical indices
    # ------------------------------------------------------------------

    def test_toc_hierarchy_produces_decimal_indices(self):
        """Parts with sub-chapters yield indices like 1.1, 1.2, 2.1, 2.2."""
        ncx_parts = ""
        for p in range(1, 3):
            children = "".join(
                _nav_point(f"c{p}_{c}", f"Chapter {p}.{c}", f"ch{p}_{c}.xhtml") for c in range(1, 3)
            )
            ncx_parts += _nav_point(f"part{p}", f"Part {p}", f"part{p}.xhtml", children=children)

        ncx = _ncx(ncx_parts)
        builder = EpubBuilder().set_ncx(ncx)
        for p in range(1, 3):
            builder.add_spine_file(f"part{p}", f"<h1>Part {p}</h1>")
            for c in range(1, 3):
                builder.add_spine_file(
                    f"ch{p}_{c}", f"<h2>Chapter {p}.{c}</h2><p>Chapter text here.</p>"
                )
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        # Sub-chapters must have two-component decimal indices
        sub_indices = [idx for idx in indices if "." in idx and not idx.endswith(".0")]
        self.assertGreaterEqual(len(sub_indices), 4, f"Expected ≥4 sub-indices, got: {indices}")
        self.assertIn("1.1", indices)
        self.assertIn("1.2", indices)
        self.assertIn("2.1", indices)
        self.assertIn("2.2", indices)

    def test_it_style_hierarchy_indices(self):
        """Simulates IT structure: 3 Parts each with 3 chapters → 3.x indices."""
        ncx_parts = ""
        for p in range(1, 4):
            children = "".join(
                _nav_point(f"c{p}_{c}", f"Chapter {p}.{c}", f"ch{p}_{c}.xhtml") for c in range(1, 4)
            )
            ncx_parts += _nav_point(f"part{p}", f"Part {p}", f"part{p}.xhtml", children=children)

        builder = EpubBuilder().set_ncx(_ncx(ncx_parts))
        for p in range(1, 4):
            builder.add_spine_file(f"part{p}", f"<h1>Part {p}</h1>")
            for c in range(1, 4):
                builder.add_spine_file(f"ch{p}_{c}", f"<h2>Chapter {p}.{c}</h2><p>Content.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        for p in range(1, 4):
            for c in range(1, 4):
                self.assertIn(f"{p}.{c}", indices, f"Missing index {p}.{c}")

    # ------------------------------------------------------------------
    # Point 2: Split chapters get unique sub-indices
    # ------------------------------------------------------------------

    def test_split_chapters_get_unique_sub_indices(self):
        """When two spine files map to the same TOC chapter, they get .1/.2 suffixes."""
        # Two spine files that share one TOC entry — simulates paragraph-split behaviour.
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=(_nav_point("ch1", "Chapter 1", "ch1a.xhtml")),
            )
        )
        builder = EpubBuilder().set_ncx(ncx)
        builder.add_spine_file("part1", "<h1>Part 1</h1>")
        # Two spine files for the same TOC chapter (ch1a.xhtml is the TOC href, ch1b not in TOC)
        builder.add_spine_file("ch1a", "<h2>Chapter 1</h2><p>First half of chapter.</p>")
        builder.add_spine_file("ch1b", "<h2>Chapter 1 cont</h2><p>Second half of chapter.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        # The two spine files that ended up with the same TOC index must be distinguished
        plain_dupes = [idx for idx in indices if indices.count(idx) > 1]
        self.assertEqual(plain_dupes, [], f"Duplicate indices found: {indices}")

    def test_three_split_parts_get_sequential_sub_indices(self):
        """Three spine files sharing the same chapter index get .1, .2, .3."""
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=(_nav_point("ch1", "Chapter 1", "ch1a.xhtml")),
            )
        )
        builder = EpubBuilder().set_ncx(ncx)
        builder.add_spine_file("part1", "<h1>Part 1</h1>")
        builder.add_spine_file("ch1a", "<h2>Chapter 1</h2><p>Part A.</p>")
        builder.add_spine_file("ch1b", "<p>Part B.</p>")
        builder.add_spine_file("ch1c", "<p>Part C.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        # Find all indices that came from the split chapter
        sub_indices = [
            item.index
            for item in items
            if ".1." in item.index
            or item.index.endswith(".1")
            or item.index.endswith(".2")
            or item.index.endswith(".3")
        ]
        # There must be no duplicates at all
        indices = [item.index for item in items]
        self.assertEqual(len(set(indices)), len(indices), f"Duplicate indices: {indices}")

    def test_split_indices_are_addressable_via_parent_selector(self):
        """Split sub-indices like '4.3.1' are addressable by parent selector '4.3'.

        The selector matching in _match_selector already handles this via the
        startswith check. This test verifies the indices produced by the post-processing
        carry the correct prefix so that the selector logic will find them.
        """

        # Build an epub where Chapter 3 maps to multiple spine files (both TOC-matched
        # and a continuation file), producing a split scenario.
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=(
                    _nav_point("ch1", "Chapter 1", "ch1.xhtml")
                    + _nav_point("ch2", "Chapter 2", "ch2.xhtml")
                    + _nav_point("ch3", "Chapter 3", "ch3a.xhtml")
                ),
            )
        )
        builder = EpubBuilder().set_ncx(ncx)
        builder.add_spine_file("part1", "<h1>Part 1</h1>")
        builder.add_spine_file("ch1", "<h2>Chapter 1</h2><p>Text.</p>")
        builder.add_spine_file("ch2", "<h2>Chapter 2</h2><p>Text.</p>")
        # ch3a is in TOC; ch3b is a spine-only continuation — both land on same TOC index
        builder.add_spine_file("ch3a", "<h2>Chapter 3</h2><p>First half.</p>")
        builder.add_spine_file("ch3b", "<p>Second half.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        # No duplicates must remain
        self.assertEqual(len(set(indices)), len(indices), f"Duplicate indices: {indices}")

        # Any index with three dotted components (x.y.z) must start with the
        # two-component prefix (x.y) — verifying addressability by parent selector.
        for idx in indices:
            parts = idx.split(".")
            if len(parts) == 3:
                parent = f"{parts[0]}.{parts[1]}"
                self.assertTrue(
                    idx.startswith(f"{parent}."),
                    f"Index {idx!r} not addressable by parent {parent!r}",
                )

    # ------------------------------------------------------------------
    # Point 3: Short single-part chapters keep plain index
    # ------------------------------------------------------------------

    def test_single_chapter_keeps_plain_index(self):
        """A chapter with no TOC sub-children and no splitting keeps a plain index like '3'."""
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=(_nav_point("ch1", "Chapter 1", "ch1.xhtml")),
            )
            + _nav_point("interlude", "Interlude", "interlude.xhtml")
            + _nav_point(
                "part2",
                "Part 2",
                "part2.xhtml",
                children=(_nav_point("ch2", "Chapter 2", "ch2.xhtml")),
            )
        )
        builder = EpubBuilder().set_ncx(ncx)
        builder.add_spine_file("part1", "<h1>Part 1</h1>")
        builder.add_spine_file("ch1", "<h2>Chapter 1</h2><p>Text.</p>")
        builder.add_spine_file("interlude", "<h1>Interlude</h1><p>Short quote.</p>")
        builder.add_spine_file("part2", "<h1>Part 2</h1>")
        builder.add_spine_file("ch2", "<h2>Chapter 2</h2><p>Text.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        # Interlude appears once → should keep its plain index (no .1 suffix)
        interlude_items = [it for it in items if "Interlude" in (it.main_title or "")]
        self.assertEqual(
            len(interlude_items), 1, f"Expected exactly 1 interlude item, got: {indices}"
        )
        self.assertNotIn(
            ".",
            interlude_items[0].index.replace(".", "x", 0),
            f"Expected plain index for interlude, got: {interlude_items[0].index!r}",
        )
        # Actually just verify the index doesn't end with .1
        self.assertFalse(
            interlude_items[0].index.endswith(".1"),
            f"Interlude should not get .1 suffix, got: {interlude_items[0].index!r}",
        )

    def test_no_duplicate_indices_in_it_style_book(self):
        """Full IT-style book with 5 parts × 5 chapters produces all-unique indices."""
        ncx_parts = ""
        for p in range(1, 6):
            children = "".join(
                _nav_point(f"c{p}_{c}", f"Chapter {p}.{c}", f"ch{p}_{c}.xhtml") for c in range(1, 6)
            )
            ncx_parts += _nav_point(f"part{p}", f"Part {p}", f"part{p}.xhtml", children=children)
            ncx_parts += _nav_point(f"interlude{p}", f"Interlude {p}", f"interlude{p}.xhtml")

        builder = EpubBuilder().set_ncx(_ncx(ncx_parts))
        for p in range(1, 6):
            builder.add_spine_file(f"part{p}", f"<h1>Part {p}</h1>")
            for c in range(1, 6):
                builder.add_spine_file(f"ch{p}_{c}", f"<h2>Ch {p}.{c}</h2><p>Content.</p>")
            builder.add_spine_file(f"interlude{p}", f"<h1>Interlude {p}</h1><p>Quote.</p>")

        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        self.assertEqual(
            len(set(indices)),
            len(indices),
            f"Duplicate indices found: {[i for i in indices if indices.count(i) > 1]}",
        )


if __name__ == "__main__":
    unittest.main()
