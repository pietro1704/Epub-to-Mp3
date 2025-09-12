# -*- coding: utf-8 -*-
"""
Unit tests for data classes (Chapter, Book) and module constants
"""

import unittest
import re
from src.ebook_reader import (
    Chapter, Book, XML_NS, TAG_RE, WHITESPACE_RE, 
    NBSP_RE, PARA_BLOCK_RE, H_TAG, PDF_AVAILABLE
)


class TestDataClasses(unittest.TestCase):
    """Test cases for Chapter and Book data classes"""

    def test_chapter_creation(self):
        """Test Chapter dataclass creation and attributes"""
        chapter = Chapter(
            index=1,
            name="Test Chapter",
            source_path="chapter1.html",
            text="This is the chapter content."
        )
        
        self.assertEqual(chapter.index, 1)
        self.assertEqual(chapter.name, "Test Chapter")
        self.assertEqual(chapter.source_path, "chapter1.html")
        self.assertEqual(chapter.text, "This is the chapter content.")

    def test_chapter_equality(self):
        """Test Chapter equality comparison"""
        chapter1 = Chapter(1, "Chapter 1", "ch1.html", "Content 1")
        chapter2 = Chapter(1, "Chapter 1", "ch1.html", "Content 1")
        chapter3 = Chapter(2, "Chapter 2", "ch2.html", "Content 2")
        
        self.assertEqual(chapter1, chapter2)
        self.assertNotEqual(chapter1, chapter3)

    def test_chapter_repr(self):
        """Test Chapter string representation"""
        chapter = Chapter(1, "Test", "test.html", "Content")
        repr_str = repr(chapter)
        
        self.assertIn("Chapter", repr_str)
        self.assertIn("index=1", repr_str)
        self.assertIn("name='Test'", repr_str)

    def test_book_creation(self):
        """Test Book dataclass creation and attributes"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2")
        ]
        
        book = Book(
            title="Test Book",
            author="Test Author",
            chapters=chapters
        )
        
        self.assertEqual(book.title, "Test Book")
        self.assertEqual(book.author, "Test Author")
        self.assertEqual(len(book.chapters), 2)
        self.assertEqual(book.chapters[0].name, "Chapter 1")
        self.assertEqual(book.chapters[1].name, "Chapter 2")

    def test_book_equality(self):
        """Test Book equality comparison"""
        chapters1 = [Chapter(1, "Ch1", "ch1.html", "Content")]
        chapters2 = [Chapter(1, "Ch1", "ch1.html", "Content")]
        chapters3 = [Chapter(2, "Ch2", "ch2.html", "Different")]
        
        book1 = Book("Title", "Author", chapters1)
        book2 = Book("Title", "Author", chapters2)
        book3 = Book("Title", "Author", chapters3)
        
        self.assertEqual(book1, book2)
        self.assertNotEqual(book1, book3)

    def test_book_repr(self):
        """Test Book string representation"""
        chapters = [Chapter(1, "Ch1", "ch1.html", "Content")]
        book = Book("Test Title", "Test Author", chapters)
        repr_str = repr(book)
        
        self.assertIn("Book", repr_str)
        self.assertIn("title='Test Title'", repr_str)
        self.assertIn("author='Test Author'", repr_str)

    def test_book_empty_chapters(self):
        """Test Book with empty chapters list"""
        book = Book("Title", "Author", [])
        
        self.assertEqual(book.title, "Title")
        self.assertEqual(book.author, "Author")
        self.assertEqual(len(book.chapters), 0)
        self.assertEqual(book.chapters, [])


class TestModuleConstants(unittest.TestCase):
    """Test cases for module-level constants and regex patterns"""

    def test_xml_namespaces(self):
        """Test XML namespace constants"""
        self.assertIsInstance(XML_NS, dict)
        self.assertIn("ocf", XML_NS)
        self.assertIn("opf", XML_NS)
        self.assertIn("dc", XML_NS)
        self.assertIn("ncx", XML_NS)
        
        # Check specific namespace URLs
        self.assertEqual(XML_NS["ocf"], "urn:oasis:names:tc:opendocument:xmlns:container")
        self.assertEqual(XML_NS["opf"], "http://www.idpf.org/2007/opf")

    def test_pdf_available_constant(self):
        """Test PDF_AVAILABLE constant is boolean"""
        self.assertIsInstance(PDF_AVAILABLE, bool)

    def test_tag_re_pattern(self):
        """Test TAG_RE regex pattern"""
        self.assertIsInstance(TAG_RE, re.Pattern)
        
        # Test pattern matches HTML tags
        self.assertTrue(TAG_RE.search("<p>"))
        self.assertTrue(TAG_RE.search("<div class='test'>"))
        self.assertTrue(TAG_RE.search("</html>"))
        
        # Test pattern doesn't match non-tags
        self.assertIsNone(TAG_RE.search("plain text"))
        self.assertIsNone(TAG_RE.search("< not a tag"))

    def test_whitespace_re_pattern(self):
        """Test WHITESPACE_RE regex pattern"""
        self.assertIsInstance(WHITESPACE_RE, re.Pattern)
        
        # Test pattern matches various whitespace
        self.assertTrue(WHITESPACE_RE.search("  "))  # spaces
        self.assertTrue(WHITESPACE_RE.search("\t"))   # tab
        self.assertTrue(WHITESPACE_RE.search("\f"))   # form feed
        self.assertTrue(WHITESPACE_RE.search("\v"))   # vertical tab
        
        # Test pattern doesn't match newlines or regular chars
        self.assertIsNone(WHITESPACE_RE.search("\n"))
        self.assertIsNone(WHITESPACE_RE.search("abc"))

    def test_nbsp_re_pattern(self):
        """Test NBSP_RE regex pattern"""
        self.assertIsInstance(NBSP_RE, re.Pattern)
        
        # Test pattern matches non-breaking spaces
        self.assertTrue(NBSP_RE.search("&nbsp;"))
        self.assertTrue(NBSP_RE.search("&NBSP;"))  # case insensitive
        self.assertTrue(NBSP_RE.search("\u00A0"))   # Unicode nbsp
        
        # Test pattern doesn't match regular spaces
        self.assertIsNone(NBSP_RE.search(" "))
        self.assertIsNone(NBSP_RE.search("&space;"))

    def test_para_block_re_pattern(self):
        """Test PARA_BLOCK_RE regex pattern"""
        self.assertIsInstance(PARA_BLOCK_RE, re.Pattern)
        
        # Test pattern matches block elements
        block_tags = ["<p>", "</p>", "<div>", "</div>", "<br>", "<li>", 
                     "<tr>", "<td>", "<th>", "<blockquote>", "<section>", 
                     "<article>", "<hr>"]
        
        for tag in block_tags:
            self.assertTrue(PARA_BLOCK_RE.search(tag), f"Should match {tag}")
        
        # Test pattern doesn't match inline elements
        self.assertIsNone(PARA_BLOCK_RE.search("<span>"))
        self.assertIsNone(PARA_BLOCK_RE.search("<strong>"))

    def test_h_tag_pattern(self):
        """Test H_TAG regex pattern"""
        self.assertIsInstance(H_TAG, re.Pattern)
        
        # Test pattern matches heading tags
        headings = [
            "<h1>Title</h1>",
            "<h2>Subtitle</h2>",
            "<h3>Section</h3>",
            "<h4>Subsection</h4>",
            "<h5>Minor heading</h5>",
            "<h6>Smallest heading</h6>"
        ]
        
        for heading in headings:
            match = H_TAG.search(heading)
            self.assertIsNotNone(match, f"Should match {heading}")
            
        # Test pattern extracts content
        match = H_TAG.search("<h1>Test Title</h1>")
        self.assertEqual(match.group(1), "1")  # heading level
        self.assertEqual(match.group(2), "Test Title")  # content
        
        # Test pattern doesn't match non-heading tags
        self.assertIsNone(H_TAG.search("<h7>Invalid</h7>"))
        self.assertIsNone(H_TAG.search("<p>Paragraph</p>"))

    def test_h_tag_case_insensitive(self):
        """Test H_TAG is case insensitive"""
        # Test case insensitive matching
        self.assertTrue(H_TAG.search("<H1>Title</H1>"))
        self.assertTrue(H_TAG.search("<h1>Title</H1>"))  # mixed case
        
    def test_h_tag_with_attributes(self):
        """Test H_TAG matches headings with attributes"""
        heading_with_attrs = '<h1 class="title" id="main">Title</h1>'
        match = H_TAG.search(heading_with_attrs)
        
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "1")
        self.assertEqual(match.group(2), "Title")

    def test_h_tag_multiline_content(self):
        """Test H_TAG matches multiline heading content"""
        multiline_heading = """<h1>Title
        with multiple
        lines</h1>"""
        
        match = H_TAG.search(multiline_heading)
        self.assertIsNotNone(match)
        self.assertIn("Title", match.group(2))
        self.assertIn("multiple", match.group(2))
        self.assertIn("lines", match.group(2))


class TestModuleImports(unittest.TestCase):
    """Test module import behavior and __all__ exports"""

    def test_all_exports(self):
        """Test __all__ contains expected exports"""
        from src.ebook_reader import __all__
        
        expected_exports = ["EbookReader", "read_book", "Book", "Chapter"]
        self.assertEqual(set(__all__), set(expected_exports))

    def test_imports_available(self):
        """Test that all expected classes and functions can be imported"""
        from src.ebook_reader import EbookReader, read_book, Book, Chapter
        from src.ebook_reader import TextProcessor, EpubParser, PdfParser
        
        # Test classes exist and are callable
        self.assertTrue(callable(EbookReader))
        self.assertTrue(callable(read_book))
        self.assertTrue(callable(Book))
        self.assertTrue(callable(Chapter))
        self.assertTrue(callable(TextProcessor))
        self.assertTrue(callable(EpubParser))
        self.assertTrue(callable(PdfParser))

    def test_pdf_import_handling(self):
        """Test PDF import is handled gracefully"""
        # This tests the try/except block for pypdf import
        from src.ebook_reader import PDF_AVAILABLE
        
        # Should be boolean regardless of whether pypdf is available
        self.assertIsInstance(PDF_AVAILABLE, bool)


if __name__ == '__main__':
    unittest.main()