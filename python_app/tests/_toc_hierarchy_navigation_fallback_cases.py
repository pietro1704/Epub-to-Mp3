"""Navigation Fallback regression scenarios, collected by test_toc_hierarchy."""

from python_app.tests._toc_hierarchy_test_support import EpubBuilder as EpubBuilder
from python_app.tests._toc_hierarchy_test_support import EpubParser as EpubParser
from python_app.tests._toc_hierarchy_test_support import _container_xml as _container_xml
from python_app.tests._toc_hierarchy_test_support import _nav_point as _nav_point
from python_app.tests._toc_hierarchy_test_support import _nav_xhtml as _nav_xhtml
from python_app.tests._toc_hierarchy_test_support import _ncx as _ncx
from python_app.tests._toc_hierarchy_test_support import _opf as _opf
from python_app.tests._toc_hierarchy_test_support import _xhtml as _xhtml
from python_app.tests._toc_hierarchy_test_support import os as os
from python_app.tests._toc_hierarchy_test_support import tempfile as tempfile
from python_app.tests._toc_hierarchy_test_support import unittest as unittest
from python_app.tests._toc_hierarchy_test_support import zipfile as zipfile


class TestEpub3NavFallback(unittest.TestCase):
    """EPUB3 books with nav.xhtml and no NCX file."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

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
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

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


class TestNcxFallbackToNav(unittest.TestCase):
    """When NCX is malformed/missing navMap, EPUB3 nav.xhtml fallback is used."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

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




class TestFilesNotInToc(unittest.TestCase):
    """Spine files not referenced in the TOC keep their default level (1)."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

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
