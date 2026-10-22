"""Css subchapter scenarios sharing the original unittest fixture."""

from python_app.tests._ebook_reader_test_support import (
    EbookReader as EbookReader,
    EpubParser as EpubParser,
    os as os,
    tempfile as tempfile,
)

class CssSubchapterCases:
    # ------------------------------------------------------------------ unit tests for static methods

    def test_split_on_markers_it_style_number_plus_title(self):
        """Detects the IT book pattern: class_s3P-0 "1" + class_sG5 title, then
        class_s42-0 "N" + class_sG5 title for subsequent sections."""
        html = (
            '<p class="class_s3J-0">Chapter 11</p>'
            '<p class="class_s3M-0">Walks</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Ben makes a retreat</p>'
            '<p class="class_s1S-1">Body of section 1.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_sG5">Richie builds castles</p>'
            '<p class="class_s1S-1">Body of section 2.</p>'
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, 11, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )

        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0][0], "11.1")
        self.assertEqual(result[0][1], "Ben makes a retreat")
        self.assertEqual(result[1][0], "11.2")
        self.assertEqual(result[1][1], "Richie builds castles")

    def test_split_on_markers_number_at_start_of_correct_fragment(self):
        """The section-number paragraph must be at the START of its fragment,
        not appended to the previous one (regression for the original split-at-title bug)."""
        html = (
            '<p class="class_s3J-0">Chapter 11</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Section One</p>'
            '<p class="body">First section content.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_sG5">Section Two</p>'
            '<p class="body">Second section content.</p>'
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, 5, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )

        self.assertIsNotNone(result)
        frag1, frag2 = result[0][2], result[1][2]
        # class_s42-0 "2" must be in fragment 2, not fragment 1.
        self.assertIn("class_s42-0", frag2)
        self.assertNotIn("class_s42-0", frag1)
        # class_s3P-0 "1" is in fragment 1 (via preamble prepend).
        self.assertIn("class_s3P-0", frag1)

    def test_split_on_markers_preamble_in_first_fragment(self):
        """Content before the first number element is included in the first fragment."""
        html = (
            '<p class="class_s3J-0">Chapter Title</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Section One</p>'
            "<p>Section one body.</p>"
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, 5, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )

        self.assertIsNotNone(result)
        self.assertEqual(len(result), 1)
        # Preamble paragraph class must appear in the first fragment.
        self.assertIn("class_s3J-0", result[0][2])

    def test_split_on_markers_no_markers_returns_none(self):
        """Returns None when the HTML contains no subchapter number elements."""
        html = "<p>Just a normal paragraph.</p><p>Another paragraph.</p>"
        result = EpubParser._split_html_on_subchapter_markers(
            html, 3, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNone(result)

    def test_split_on_markers_empty_number_class_set_returns_none(self):
        """Returns None when the number class set is empty."""
        html = '<p class="class_s3P-0">1</p>' '<p class="class_sG5">Title</p><p>Body.</p>'
        result = EpubParser._split_html_on_subchapter_markers(html, 1, frozenset(), "class_sG5")
        self.assertIsNone(result)

    def test_split_on_markers_number_without_following_title_is_skipped(self):
        """A number element with no paragraph closing within the 2000-char fallback
        window is skipped (the split is abandoned for that marker)."""
        # The noise paragraph is 2100 chars long — its </p> is outside the 2000-char
        # fallback window, so neither the explicit title search nor the any-paragraph
        # fallback finds content, and the number element is skipped → None.
        html = (
            '<p class="class_s42-0">2</p>'
            + '<p class="noise">'
            + "x" * 2100
            + "</p>"
            + '<p class="class_sG5">Late title</p>'
            + "<p>Body.</p>"
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, 3, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNone(result)

    def test_split_on_markers_string_parent_index(self):
        """Parent index can be a string; sub-indices are formatted correctly."""
        html = (
            '<p class="class_s3P-0">1</p><p class="class_sG5">A</p><p>body a</p>'
            '<p class="class_s42-0">2</p><p class="class_sG5">B</p><p>body b</p>'
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, "7", frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNotNone(result)
        self.assertEqual(result[0][0], "7.1")
        self.assertEqual(result[1][0], "7.2")

    def test_split_on_markers_six_subchapters_it_style(self):
        """All 6 subchapter markers in IT ch.11 are detected correctly."""
        parts = [
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Section 1</p>'
            '<p class="body">Content of section 1.</p>'
        ]
        for i in range(2, 7):
            parts.append(
                f'<p class="class_s42-0">{i}</p>'
                f'<p class="class_sG5">Section {i}</p>'
                f'<p class="body">Content of section {i}.</p>'
            )
        html = '<p class="class_s3J-0">Chapter 11</p>' + "".join(parts)
        result = EpubParser._split_html_on_subchapter_markers(
            html, 11, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 6)
        for i, entry in enumerate(result, start=1):
            idx, title = entry[0], entry[1]
            self.assertEqual(idx, f"11.{i}")
            self.assertEqual(title, f"Section {i}")

    # ------------------------------------------------------------------ integration tests

    def test_epub_with_subchapter_markers_creates_decimal_chapters(self):
        """Full EPUB parse: IT-style number+title markers produce decimal-indexed chapters."""
        chapter_html = (
            '<?xml version="1.0" encoding="utf-8"?>'
            "<!DOCTYPE html>"
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            "<head><title>Chapter 11</title></head><body>"
            '<div class="class_s11-0">'
            '<p class="class_s3J-0">Chapter 11</p>'
            '<p class="class_s3M-0">Walks</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Ben makes a retreat</p>'
            '<p class="class_s1S-1">This is the first section body text here.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_sG5">Richie builds castles</p>'
            '<p class="class_s1S-1">This is the second section body text here.</p>'
            "</div></body></html>"
        )
        epub_bytes = self._build_epub_bytes(chapter_html)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tmp:
            tmp.write(epub_bytes)
            tmp_path = tmp.name
        try:
            reader = EbookReader(tmp_path)
            chapters = reader.get_chapters()
        finally:
            os.unlink(tmp_path)

        self.assertEqual(len(chapters), 2)
        self.assertEqual(chapters[0].index, "1.1")
        self.assertEqual(chapters[0].name, "Ben makes a retreat")
        self.assertIn("first section body", chapters[0].text)
        self.assertEqual(chapters[1].index, "1.2")
        self.assertEqual(chapters[1].name, "Richie builds castles")
        self.assertIn("second section body", chapters[1].text)

    def test_epub_without_markers_single_chapter(self):
        """EPUB without subchapter markers produces a single Chapter per spine file."""
        chapter_html = (
            '<?xml version="1.0" encoding="utf-8"?>'
            "<!DOCTYPE html>"
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            "<head><title>Chapter 1</title></head><body>"
            "<h1>Chapter One</h1>"
            "<p>This is the body text without any subchapter markers.</p>"
            "</body></html>"
        )
        epub_bytes = self._build_epub_bytes(chapter_html)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tmp:
            tmp.write(epub_bytes)
            tmp_path = tmp.name
        try:
            reader = EbookReader(tmp_path)
            chapters = reader.get_chapters()
        finally:
            os.unlink(tmp_path)

        self.assertEqual(len(chapters), 1)
        self.assertIsInstance(chapters[0].index, int)

    # ------------------------------------------------------------------ ch4-style (no class_sG5 title)

    def test_split_markers_no_title_class_fallback_to_first_paragraph(self):
        """When no class_sG5 follows the number marker, the first paragraph's
        text is used as the section title (IT chapter-4 pattern)."""
        # This mirrors the real HTML structure of "It: A coisa" ch.4 where section
        # numbers are NOT followed by a dedicated class_sG5 title paragraph.
        html = (
            '<div class="class_s11-0">'
            '<p class="class_s3J-0">Capítulo 4</p>'
            '<p class="class_s3M-0">Ben Hanscom sofre uma queda</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_s1PD-0">Por volta das 23h45, uma das comissárias.</p>'
            '<p class="class_s4G-0">A escola.</p>'
            '<p class="class_s4G-0">A escola</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_s1S-0">acabou!</p>'
            '<p class="class_s3T-0">O som do sino se espalhou pelos corredores.</p>'
            "</div>"
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html,
            "5.1",
            frozenset({"class_s3P-0", "class_s42-0"}),
            "class_sG5",
        )

        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)

        # Section 1
        idx1, title1, frag1, explicit1 = result[0]
        self.assertEqual(idx1, "5.1.1")
        self.assertFalse(explicit1, "title was derived from content, not class_sG5")
        self.assertIn("Por volta das 23h45", title1)
        # Section 1 fragment ends before the "2" marker
        self.assertNotIn('class_s42-0">2</p>', frag1)
        # Preamble (chapter heading) is in section 1
        self.assertIn("class_s3J-0", frag1)
        # Last paragraph of section 1 content is present
        self.assertIn("A escola</p>", frag1)

        # Section 2
        idx2, title2, frag2, explicit2 = result[1]
        self.assertEqual(idx2, "5.1.2")
        self.assertFalse(explicit2)
        self.assertIn("acabou", title2)
        # Section 2 fragment starts with the "2" marker
        self.assertTrue(
            frag2.lstrip().startswith('<p class="class_s42-0">2</p>'),
            f"Expected section 2 to start with the number marker, got: {frag2[:80]!r}",
        )
        self.assertIn("O som do sino", frag2)

    def test_split_markers_with_explicit_title_keeps_has_explicit_true(self):
        """Sections that DO have a class_sG5 title report has_explicit_title=True."""
        html = (
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Stanley Uris toma um banho</p>'
            '<p class="body">Content here.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_sG5">Richie Tozier liga</p>'
            '<p class="body">More content.</p>'
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, "4.3", frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)
        _, title1, _, explicit1 = result[0]
        _, title2, _, explicit2 = result[1]
        self.assertTrue(explicit1)
        self.assertTrue(explicit2)
        self.assertEqual(title1, "Stanley Uris toma um banho")
        self.assertEqual(title2, "Richie Tozier liga")
