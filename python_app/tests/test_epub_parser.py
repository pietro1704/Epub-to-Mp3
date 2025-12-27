# -*- coding: utf-8 -*-
"""
Unit tests for EpubParser class
"""

import os
import tempfile
import unittest
import zipfile

from src.ebook_reader import Book, EbookReader, EpubParser


class TestEpubParser(unittest.TestCase):
    """Test cases for EpubParser class"""

    def setUp(self):
        """Set up test fixtures"""
        self.temp_dir = tempfile.mkdtemp()
        self.sample_epub_path = os.path.join(self.temp_dir, "test.epub")

    def tearDown(self):
        """Clean up test fixtures"""
        if os.path.exists(self.sample_epub_path):
            os.remove(self.sample_epub_path)
        os.rmdir(self.temp_dir)

    def create_mock_epub(
        self,
        title="Test Book",
        author="Test Author",
        chapters_data=None,
        include_cover=True,
    ):
        """Create a mock EPUB file for testing"""
        if chapters_data is None:
            chapters_data = [
                ("chapter1.xhtml", "<h1>Chapter 1</h1><p>Content of chapter 1.</p>"),
                ("chapter2.xhtml", "<h1>Chapter 2</h1><p>Content of chapter 2.</p>"),
            ]

        # Container XML
        container_xml = """<?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>"""

        # OPF content
        manifest_items = ""
        spine_items = ""
        for i, (filename, _) in enumerate(chapters_data, 1):
            manifest_items += (
                f'<item id="chapter{i}" href="{filename}" media-type="application/xhtml+xml"/>\n'
            )
            spine_items += f'<itemref idref="chapter{i}"/>\n'

        cover_manifest = ""
        cover_meta = ""
        if include_cover:
            cover_manifest = '<item id="cover-image" href="Images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>\n'
            cover_meta = '<meta name="cover" content="cover-image"/>'

        opf_content = f"""<?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>{title}</dc:title>
                <dc:creator>{author}</dc:creator>
                {cover_meta}
            </metadata>
            <manifest>
                {manifest_items}
                {cover_manifest}
            </manifest>
            <spine>
                {spine_items}
            </spine>
        </package>"""

        # Create ZIP file
        with zipfile.ZipFile(self.sample_epub_path, "w") as zf:
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("OEBPS/content.opf", opf_content)

            for filename, content in chapters_data:
                zf.writestr(f"OEBPS/{filename}", content)
            if include_cover:
                zf.writestr("OEBPS/Images/cover.jpg", b"\xff\xd8\xff\xdbMockCoverData")

    def test_init(self):
        """Test EpubParser initialization"""
        parser = EpubParser("test.epub")
        self.assertEqual(parser.file_path, "test.epub")

    def test_parse_simple_epub(self):
        """Test parsing a simple EPUB file"""
        self.create_mock_epub()

        parser = EpubParser(self.sample_epub_path)
        book = parser.parse()

        self.assertIsInstance(book, Book)
        self.assertEqual(book.title, "Test Book")
        self.assertEqual(book.author, "Test Author")
        self.assertEqual(len(book.chapters), 2)

        # Check first chapter
        chapter1 = book.chapters[0]
        self.assertEqual(chapter1.index, 1)
        self.assertEqual(chapter1.name, "Chapter 1")
        self.assertIn("Content of chapter 1", chapter1.text)

        # Check second chapter
        chapter2 = book.chapters[1]
        self.assertEqual(chapter2.index, 2)
        self.assertEqual(chapter2.name, "Chapter 2")
        self.assertIn("Content of chapter 2", chapter2.text)

    def test_parse_epub_no_headings(self):
        """Test parsing EPUB with no headings (uses content for titles)"""
        chapters_data = [
            ("chapter1.xhtml", "<p>Esta é uma história interessante sobre aventuras.</p>"),
            ("chapter2.xhtml", "<p>Continuação da história com mais detalhes.</p>"),
        ]
        self.create_mock_epub(chapters_data=chapters_data)

        parser = EpubParser(self.sample_epub_path)
        book = parser.parse()

        # Should extract titles from content
        chapter1 = book.chapters[0]
        self.assertEqual(chapter1.name, "Esta é uma história interessante sobre")

        chapter2 = book.chapters[1]
        self.assertEqual(chapter2.name, "Continuação da história com mais detalhes.")

    def test_parse_epub_empty_chapters(self):
        """Test parsing EPUB with empty chapters"""
        chapters_data = [
            ("chapter1.xhtml", ""),
            ("chapter2.xhtml", "<p></p>"),
            ("chapter3.xhtml", "<p>Valid content here.</p>"),
        ]
        self.create_mock_epub(chapters_data=chapters_data)

        parser = EpubParser(self.sample_epub_path)
        book = parser.parse()

        self.assertEqual(len(book.chapters), 3)

        # Empty chapters should get default names
        self.assertEqual(book.chapters[0].name, "Capítulo 1")
        self.assertEqual(book.chapters[1].name, "Capítulo 2")
        self.assertEqual(book.chapters[2].name, "Valid content here.")

    def test_extract_cover_image(self):
        """EbookReader should expose cover bytes from the EPUB manifest."""
        self.create_mock_epub()
        reader = EbookReader(self.sample_epub_path)
        cover = reader.extract_cover_image()
        self.assertIsNotNone(cover, "Cover should be detected in mocked EPUB")
        assert cover is not None  # mypy/static check
        self.assertEqual(cover.extension, ".jpg")
        self.assertTrue(cover.media_type.startswith("image/"))
        self.assertGreater(len(cover.data), 0)

    def test_parse_epub_no_metadata(self):
        """Test parsing EPUB with no metadata"""
        container_xml = """<?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>"""

        opf_content = """<?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            </metadata>
            <manifest>
                <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="chapter1"/>
            </spine>
        </package>"""

        with zipfile.ZipFile(self.sample_epub_path, "w") as zf:
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("content.opf", opf_content)
            zf.writestr("chapter1.xhtml", "<h1>Test Chapter</h1>")

        parser = EpubParser(self.sample_epub_path)
        book = parser.parse()

        # Should use filename as title when no metadata
        self.assertEqual(book.title, "test")
        self.assertEqual(book.author, "")

    def test_find_opf_path_success(self):
        """Test successful OPF path finding"""
        self.create_mock_epub()

        parser = EpubParser(self.sample_epub_path)
        with zipfile.ZipFile(self.sample_epub_path, "r") as zf:
            opf_path = parser._find_opf_path(zf)
            self.assertEqual(opf_path, "OEBPS/content.opf")

    def test_find_opf_path_no_rootfile(self):
        """Test OPF path finding with no rootfile"""
        container_xml = """<?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
            </rootfiles>
        </container>"""

        with zipfile.ZipFile(self.sample_epub_path, "w") as zf:
            zf.writestr("META-INF/container.xml", container_xml)

        parser = EpubParser(self.sample_epub_path)
        with zipfile.ZipFile(self.sample_epub_path, "r") as zf:
            with self.assertRaises(RuntimeError) as context:
                parser._find_opf_path(zf)
            self.assertIn("Invalid EPUB", str(context.exception))

    def test_parse_opf_success(self):
        """Test successful OPF parsing"""
        self.create_mock_epub()

        parser = EpubParser(self.sample_epub_path)
        with zipfile.ZipFile(self.sample_epub_path, "r") as zf:
            manifest, spine_ids, title, author = parser._parse_opf(zf, "OEBPS/content.opf")

            self.assertEqual(title, "Test Book")
            self.assertEqual(author, "Test Author")
            self.assertIn("chapter1", manifest)
            self.assertIn("chapter2", manifest)
            self.assertEqual(spine_ids, ["chapter1", "chapter2"])

    def test_extract_chapters_success(self):
        """Test successful chapter extraction"""
        self.create_mock_epub()

        parser = EpubParser(self.sample_epub_path)
        with zipfile.ZipFile(self.sample_epub_path, "r") as zf:
            manifest = {"chapter1": "chapter1.xhtml", "chapter2": "chapter2.xhtml"}
            spine_ids = ["chapter1", "chapter2"]
            chapters = parser._extract_chapters(zf, manifest, spine_ids, "OEBPS")

            self.assertEqual(len(chapters), 2)
            self.assertEqual(chapters[0].name, "Chapter 1")
            self.assertEqual(chapters[1].name, "Chapter 2")

    def test_extract_chapters_missing_files(self):
        """Test chapter extraction with missing files"""
        self.create_mock_epub()

        parser = EpubParser(self.sample_epub_path)
        with zipfile.ZipFile(self.sample_epub_path, "r") as zf:
            manifest = {"chapter1": "chapter1.xhtml", "missing": "missing.xhtml"}
            spine_ids = ["chapter1", "missing"]
            chapters = parser._extract_chapters(zf, manifest, spine_ids, "OEBPS")

            # Should only return existing chapters
            self.assertEqual(len(chapters), 1)
            self.assertEqual(chapters[0].name, "Chapter 1")

    def test_extract_chapters_non_html_files(self):
        """Test chapter extraction skips non-HTML files"""
        self.create_mock_epub()

        parser = EpubParser(self.sample_epub_path)
        with zipfile.ZipFile(self.sample_epub_path, "r") as zf:
            manifest = {"chapter1": "chapter1.xhtml", "image": "image.jpg"}
            spine_ids = ["chapter1", "image"]
            chapters = parser._extract_chapters(zf, manifest, spine_ids, "OEBPS")

            # Should only return HTML chapters
            self.assertEqual(len(chapters), 1)
            self.assertEqual(chapters[0].name, "Chapter 1")

    def test_read_zip_text_utf8(self):
        """Test reading UTF-8 text from zip"""
        with zipfile.ZipFile(self.sample_epub_path, "w") as zf:
            zf.writestr("test.txt", "Hello World".encode("utf-8"))

        with zipfile.ZipFile(self.sample_epub_path, "r") as zf:
            result = EpubParser._read_zip_text(zf, "test.txt")
            self.assertEqual(result, "Hello World")

    def test_read_zip_text_latin1_fallback(self):
        """Test reading text with latin-1 fallback"""
        with zipfile.ZipFile(self.sample_epub_path, "w") as zf:
            # Create invalid UTF-8 that will trigger latin-1 fallback
            zf.writestr("test.txt", b"\xff\xfe\x00\x48\x00\x65\x00\x6c\x00\x6c\x00\x6f")

        with zipfile.ZipFile(self.sample_epub_path, "r") as zf:
            result = EpubParser._read_zip_text(zf, "test.txt")
            # Should not raise exception, should return some string
            self.assertIsInstance(result, str)

    def test_opf_dir_with_path(self):
        """Test _opf_dir with path containing directory"""
        result = EpubParser._opf_dir("OEBPS/content.opf")
        self.assertEqual(result, "OEBPS")

    def test_opf_dir_no_path(self):
        """Test _opf_dir with no directory"""
        result = EpubParser._opf_dir("content.opf")
        self.assertEqual(result, "")

    def test_join_path_no_base(self):
        """Test _join_path with no base directory"""
        result = EpubParser._join_path("", "chapter.xhtml")
        self.assertEqual(result, "chapter.xhtml")

    def test_join_path_with_base(self):
        """Test _join_path with base directory"""
        result = EpubParser._join_path("OEBPS", "chapter.xhtml")
        self.assertEqual(result, "OEBPS/chapter.xhtml")

    def test_join_path_absolute_href(self):
        """Test _join_path with absolute href"""
        result = EpubParser._join_path("OEBPS", "/chapter.xhtml")
        self.assertEqual(result, "chapter.xhtml")

    def test_is_html_like_xhtml(self):
        """Test _is_html_like with XHTML files"""
        self.assertTrue(EpubParser._is_html_like("chapter.xhtml"))
        self.assertTrue(EpubParser._is_html_like("CHAPTER.XHTML"))

    def test_is_html_like_html(self):
        """Test _is_html_like with HTML files"""
        self.assertTrue(EpubParser._is_html_like("chapter.html"))
        self.assertTrue(EpubParser._is_html_like("chapter.htm"))

    def test_is_html_like_other_files(self):
        """Test _is_html_like with non-HTML files"""
        self.assertFalse(EpubParser._is_html_like("image.jpg"))
        self.assertFalse(EpubParser._is_html_like("style.css"))
        self.assertFalse(EpubParser._is_html_like("document.pdf"))


if __name__ == "__main__":
    unittest.main()
