"""Footnote Placement regression scenarios, collected by test_ebook_reader."""

from python_app.tests._ebook_reader_test_support import (
    EbookReader as EbookReader,
    Path as Path,
    unittest as unittest,
)

class TestFootnoteNotInTocRegression(unittest.TestCase):
    """Regression tests for parser bugs fixed in ebook_reader.py.

    Bug batch 1 — endnote containers + empty chapters:
      1. Spine items whose body opens with role="doc-endnotes" / epub:type="endnotes"
         (e.g. Hobbit_note_N.xhtml) must NOT be promoted to chapters.
      2. Spine items that produce empty text (cover images, blank separators)
         must be dropped from the chapter list.

    Bug batch 2 — heading-embedded footnote refs + spurious navigation footnotes:
      3. A footnote reference inside a chapter heading (<h1 role="doc-noteref">)
         must cause the note to appear at the END of the chapter prose, not
         before the first paragraph (i.e. the heading text must be the first
         thing in chapter.text).
      4. A navigation anchor (long anchor text ≥ 3 words, e.g. "Chapter Title")
         must NOT be collected as a footnote — only short symbols/numbers qualify.

    Fixture: python_app/tests/fixtures/epubs/footnote_not_in_toc.epub
      Spine:  cover | chap1 | chap2 | note1 | note2
      TOC:              chap1   chap2
      Expected chapters: 2 (chap1 with heading-embedded noteref, chap2 with body noteref)
      cover: empty → dropped; note1/2: endnote containers → excluded.
    """

    FIXTURE = Path(__file__).parent / "fixtures" / "epubs" / "footnote_not_in_toc.epub"

    def setUp(self):
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture not found: {self.FIXTURE}")

    def _load(self):
        return EbookReader(self.FIXTURE).get_chapters()

    def test_endnote_containers_not_in_toc_are_excluded(self):
        """note1.xhtml (doc-endnotes) and note2.xhtml (epub:type=endnotes) must be excluded."""
        chapters = self._load()
        sources = [ch.source_path for ch in chapters]
        self.assertFalse(
            any("note1" in s or "note2" in s for s in sources),
            "Endnote container files must not become chapters",
        )

    def test_empty_spine_items_are_excluded(self):
        """cover.xhtml has no prose text -> must not appear as a chapter."""
        chapters = self._load()
        for ch in chapters:
            self.assertTrue(
                ch.text and ch.text.strip(),
                f"Chapter {ch.index!r} ({ch.name!r}) has empty text — should have been dropped",
            )

    def test_exactly_two_toc_chapters_returned(self):
        """Only the 2 TOC-listed chapters (chap1, chap2) should survive."""
        chapters = self._load()
        self.assertEqual(
            len(chapters),
            2,
            f"Expected 2 chapters, got {len(chapters)}: {[c.name for c in chapters]}",
        )

    def test_chapter_names_match_ncx_labels(self):
        """Chapter names must come from NCX navLabel, not from raw text."""
        chapters = self._load()
        names = [ch.name for ch in chapters]
        self.assertIn("Chapter One", names)
        self.assertIn("Chapter Two", names)

    def test_heading_embedded_footnote_appears_after_prose(self):
        """Bug batch 2 / bug 3: footnote ref inside <h1> must not prefix chapter prose.

        chap1.xhtml has <h1>Chapter One<a role="doc-noteref">*</a></h1>.
        The footnote text must NOT appear before the first paragraph;
        the chapter's first line must be the heading ("Chapter One").
        The footnote text must appear only AFTER the main prose.
        """
        chapters = self._load()
        ch1 = next(c for c in chapters if c.name == "Chapter One")
        text = ch1.text or ""

        # First line must be the clean heading, not footnote text
        first_line = text.split("\n")[0]
        self.assertEqual(
            first_line, "Chapter One", f"First line must be chapter title, got: {first_line!r}"
        )

        # The prose must come before the footnote announcement
        prose_marker = "first chapter prose"
        fn_marker = "nota de rodapé"
        prose_pos = text.find(prose_marker)
        fn_pos = text.find(fn_marker)
        self.assertGreater(prose_pos, -1, "Prose text not found in chapter")
        if fn_pos != -1:  # footnote may or may not be rendered
            self.assertLess(
                prose_pos,
                fn_pos,
                "Footnote announcement must come AFTER the prose, not before it",
            )

    def test_nav_link_in_heading_not_collected_as_footnote(self):
        """Bug batch 2 / bug 4: long-text nav anchor must not become a footnote.

        chap1.xhtml heading contains both a navigation <a> (long text = nav link)
        and a real noteref <a role='doc-noteref'>*.  Only the noteref should be
        collected; the nav link must be ignored even if its href fragment looks
        note-like (e.g. href='toc.xhtml#ch1name').
        """
        chapters = self._load()
        ch1 = next(c for c in chapters if c.name == "Chapter One")
        for fn in ch1.footnotes or []:
            fn_text = fn.get("text", "")
            # The nav link's resolved text is "Chapter One" (the chapter title).
            # That must NOT appear as a footnote.
            self.assertNotEqual(
                fn_text.strip().lower(),
                "chapter one",
                "Navigation link with full chapter title must not be collected as a footnote",
            )

    def test_note_equal_to_document_heading_is_discarded(self):
        """Bug batch 3: a note whose text equals a section heading is spurious.

        A "Maps" plate (image only) whose sole anchor is a note-like link
        pointing back at the "Maps" heading would otherwise be spoken as
        "Maps. footnote 1... Maps. end of footnote...". The heading-text guard
        in _collect_footnotes_bs4 must drop it. Observed on the full
        Lord of the Rings conversion (2026-07-03).
        """
        from bs4 import BeautifulSoup

        from python_app.src.ebook_reader import TextProcessor

        markup = (
            "<html><body>"
            '<h1 id="maps">Maps</h1>'
            '<p>See the map<a href="#maps" epub:type="noteref">1</a>.</p>'
            "</body></html>"
        )
        _, footnotes = TextProcessor._collect_footnotes_bs4(markup, BeautifulSoup)
        for fn in footnotes:
            self.assertNotEqual(
                (fn.get("text", "") or "").strip().rstrip(".").lower(),
                "maps",
                "A note whose text equals a document heading must be discarded",
            )

    def test_real_footnote_not_discarded_by_heading_guard(self):
        """The heading guard must not drop a legitimate note.

        A real note whose text differs from every heading must survive.
        """
        from bs4 import BeautifulSoup

        from python_app.src.ebook_reader import TextProcessor

        markup = (
            "<html><body>"
            '<h1 id="chap">Chapter</h1>'
            '<p>Some prose<a href="#fn1" epub:type="noteref">1</a>.</p>'
            '<aside id="fn1" epub:type="footnote">A genuine footnote body.</aside>'
            "</body></html>"
        )
        _, footnotes = TextProcessor._collect_footnotes_bs4(markup, BeautifulSoup)
        self.assertTrue(
            any("genuine footnote" in (fn.get("text", "") or "").lower() for fn in footnotes),
            "A legitimate footnote must not be dropped by the heading guard",
        )
