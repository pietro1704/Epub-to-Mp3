"""Locale Cues regression scenarios, collected by test_ebook_reader."""

from python_app.tests._ebook_reader_test_support import (
    EpubParser as EpubParser,
    os as os,
    tempfile as tempfile,
    unittest as unittest,
    zipfile as zipfile,
)

class TestCueLocaleFollowsBookLanguage(unittest.TestCase):
    """Regression: English books must get English verbal cues, not pt-BR ones.

    Bug: TextFormattingProcessor.DEFAULT_CUE_LOCALE was 'pt', and
    _prepare_speech_text() created it without passing the book's language.
    Result: 'em itálico' / 'fim do itálico' were injected into English chapters.
    Fix: _extract_chapters derives cue_locale from book_language and propagates it.
    """

    def _make_epub_with_italic(self, lang: str) -> bytes:
        """Build a minimal EPUB with one chapter containing italic text."""
        import io
        import zipfile

        container_xml = b"""<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""

        opf_lang = lang
        opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-cue-locale</dc:identifier>
    <dc:title>Cue Locale Test</dc:title>
    <dc:language>{opf_lang}</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
  </spine>
</package>""".encode()

        ncx = b"""<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-cue-locale"/></head>
  <docTitle><text>Cue Locale Test</text></docTitle>
  <navMap>
    <navPoint id="ch1" playOrder="1">
      <navLabel><text>Chapter One</text></navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>"""

        chapter_xhtml = b"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter One</title></head>
  <body>
    <h1>Chapter One</h1>
    <p>This sentence has <em>italic words</em> in it.</p>
    <p>Another paragraph follows.</p>
  </body>
</html>"""

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("mimetype", "application/epub+zip")
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("OEBPS/content.opf", opf)
            zf.writestr("OEBPS/toc.ncx", ncx)
            zf.writestr("OEBPS/chapter1.xhtml", chapter_xhtml)
        buf.seek(0)
        return buf.read()

    def _parse_epub(self, lang: str):
        import os
        import tempfile

        from python_app.src.ebook_reader import EpubParser

        epub_bytes = self._make_epub_with_italic(lang)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as f:
            f.write(epub_bytes)
            path = f.name
        try:
            parser = EpubParser(path)
            book = parser.parse()
            return book.chapters
        finally:
            os.unlink(path)

    def test_english_book_no_ptbr_cues(self):
        """English EPUB must not produce em itálico / fim do itálico cues.

        The verbal cues live in speech_text (TTS payload), not ch.text
        (plain-text store).  We check speech_text.
        """
        chapters = self._parse_epub("en")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        self.assertNotIn(
            "em itálico",
            speech,
            "English book must not emit pt-BR cue 'em itálico' in speech_text",
        )
        self.assertNotIn(
            "fim do itálico",
            speech,
            "English book must not emit pt-BR cue 'fim do itálico' in speech_text",
        )

    def test_portuguese_book_gets_ptbr_cues(self):
        """pt-BR EPUB must produce pt-BR cues in speech_text (TTS payload)."""
        chapters = self._parse_epub("pt-BR")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        self.assertIn(
            "em itálico",
            speech,
            "Portuguese book must emit pt-BR cue 'em itálico' in speech_text",
        )

    def test_english_book_gets_english_cues(self):
        """English EPUB must produce English verbal cues in speech_text."""
        chapters = self._parse_epub("en")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        # The italic source word must be present; pt-BR cue must not be.
        self.assertIn(
            "italic words",
            speech,
            "English book: italic source text must be present in speech_text",
        )
        self.assertNotIn(
            "em itálico",
            speech,
            "English book must not have pt-BR cue 'em itálico' in speech_text",
        )

    def _make_epub_with_footnote(self, lang: str) -> bytes:
        """Build a minimal EPUB with one chapter containing a footnote reference."""
        import io
        import zipfile

        container_xml = b"""<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""

        opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-fn-locale</dc:identifier>
    <dc:title>Footnote Locale Test</dc:title>
    <dc:language>{lang}</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
  </spine>
</package>""".encode()

        ncx = b"""<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-fn-locale"/></head>
  <docTitle><text>Footnote Locale Test</text></docTitle>
  <navMap>
    <navPoint id="ch1" playOrder="1">
      <navLabel><text>Chapter One</text></navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>"""

        # Chapter with an inline footnote reference (doc-noteref / aside)
        chapter_xhtml = b"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Chapter One</title></head>
  <body>
    <h1>Chapter One</h1>
    <p>The main prose continues here.<a id="fnref1" href="#fn1" role="doc-noteref">*</a></p>
    <p>Second paragraph.</p>
    <aside id="fn1" epub:type="footnote">
      <p>This is the footnote body text.</p>
    </aside>
  </body>
</html>"""

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("mimetype", "application/epub+zip")
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("OEBPS/content.opf", opf)
            zf.writestr("OEBPS/toc.ncx", ncx)
            zf.writestr("OEBPS/chapter1.xhtml", chapter_xhtml)
        buf.seek(0)
        return buf.read()

    def _parse_epub_fn(self, lang: str):
        import os
        import tempfile

        from python_app.src.ebook_reader import EpubParser

        epub_bytes = self._make_epub_with_footnote(lang)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as f:
            f.write(epub_bytes)
            path = f.name
        try:
            parser = EpubParser(path)
            book = parser.parse()
            return book.chapters
        finally:
            os.unlink(path)

    def test_english_book_footnote_labels_in_english(self):
        """English EPUB footnote labels must be 'footnote N' / 'end of footnote'.

        Regression: _render_footnotes had pt-BR defaults ('nota de rodapé', 'fim
        da nota de rodapé') hard-coded and no locale was passed from call sites.
        """
        chapters = self._parse_epub_fn("en")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        self.assertNotIn(
            "nota de rodapé",
            speech,
            "English EPUB footnote must not contain pt-BR label 'nota de rodapé'",
        )
        self.assertIn(
            "footnote",
            speech,
            "English EPUB footnote must contain English label 'footnote'",
        )

    def test_portuguese_book_footnote_labels_in_portuguese(self):
        """pt-BR EPUB footnote labels must remain 'nota de rodapé' / 'fim da nota de rodapé'."""
        chapters = self._parse_epub_fn("pt-BR")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        self.assertIn(
            "nota de rodapé",
            speech,
            "Portuguese EPUB footnote must contain pt-BR label 'nota de rodapé'",
        )
        self.assertNotIn(
            "end of footnote",
            speech,
            "Portuguese EPUB footnote must not use English label 'end of footnote'",
        )
