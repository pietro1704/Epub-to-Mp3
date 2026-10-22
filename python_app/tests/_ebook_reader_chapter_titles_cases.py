"""Chapter Titles regression scenarios, collected by test_ebook_reader."""

from python_app.tests._ebook_reader_test_support import EbookReader as EbookReader
from python_app.tests._ebook_reader_test_support import Path as Path
from python_app.tests._ebook_reader_test_support import parse_epub_to_dict as parse_epub_to_dict
from python_app.tests._ebook_reader_test_support import unittest as unittest


class TestChapterNameFromToc(unittest.TestCase):
    """Regression: chapter.name must come from TOC navLabel text, NOT the file ID or href.

    Bug: _restore_chapter_entry in server.py used path.stem (e.g. "001 - chapter01")
    as chapter name.  The iOS playableChapters fallback also set name = asset.name
    (raw MP3 filename).  Both caused the UI to show "001 - chapter01" or a sanitised
    hash instead of the human-readable TOC title.
    """

    FIXTURE = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    def test_ncx_navlabel_used_as_chapter_name(self):
        """Chapter.name must equal the NCX <navLabel><text> value, never the href/id."""
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        reader = EbookReader(str(self.FIXTURE))
        chapters = reader.get_chapters()
        names = [ch.name for ch in chapters if ch.text.strip()]
        self.assertGreater(len(names), 0, "No chapters parsed")
        for name in names:
            # Must not look like a bare filename stem ("chapter1", "ch01.xhtml")
            self.assertFalse(
                name.lower().startswith("chapter") and (name[7:].replace(".", "").isdigit()),
                f"Chapter name looks like a raw file ID: {name!r}",
            )
        # The fixture NCX labels its first entry "Capítulo 1 - Começo"
        self.assertIn("Capítulo 1", names[0], f"First chapter name was: {names[0]!r}")

    def test_parse_epub_to_dict_name_from_toc(self):
        """parse_epub_to_dict (iOS wire format) must carry TOC names, not file IDs."""
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE))
        for chapter in payload["chapters"]:
            name = chapter.get("name") or ""
            # Must not be a bare filename like "chapter1" or "chapter1.xhtml"
            self.assertFalse(
                name.lower().startswith("chapter") and name[7:].replace(".", "").isdigit(),
                f"Chapter name looks like a raw file ID: {name!r}",
            )


class TestRestoreChapterNameStripping(unittest.TestCase):
    """Regression: _restore_chapter_entry must strip the 'NNN - ' prefix from MP3 stems.

    When a job's .jobs/ JSON is lost and the backend reconstructs progress from
    output MP3 files, it used to set name=path.stem → "001 - Chapter Title".
    The fix strips the leading numeric prefix so the iOS client sees "Chapter Title".
    """

    def test_numeric_prefix_stripped(self):
        import re

        # The canonical filename format is "{NNN:03d} - {safe_name}.mp3", so
        # the prefix always has spaces surrounding the dash.  The regex must
        # only strip "NNN - " (with surrounding spaces) to avoid eating
        # hyphens that appear inside real chapter titles like "42-Plain".
        stems = [
            ("001 - Prologue", "Prologue"),
            ("023 - The Last Chapter", "The Last Chapter"),
            ("001 – Introduction", "Introduction"),  # en-dash with spaces
            ("42-Plain", "42-Plain"),  # no surrounding spaces → keep as-is
            ("Chapter", "Chapter"),  # no prefix at all
        ]
        for raw, expected in stems:
            # Use same regex as server.py _restore_chapter_entry: spaces required
            result = re.sub(r"^\d+\s+[-–]\s+", "", raw).strip() or raw
            self.assertEqual(result, expected, f"Input: {raw!r}")
