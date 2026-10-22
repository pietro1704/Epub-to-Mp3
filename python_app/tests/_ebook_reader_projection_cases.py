"""Projection regression scenarios, collected by test_ebook_reader."""

from python_app.tests._ebook_reader_test_support import (
    Book as Book,
    Chapter as Chapter,
    EbookReader as EbookReader,
    EpubParser as EpubParser,
    Path as Path,
    TocItem as TocItem,
    parse_epub_to_dict as parse_epub_to_dict,
    patch as patch,
    tempfile as tempfile,
    unittest as unittest,
    zipfile as zipfile,
)

class TestParseEpubToDict(unittest.TestCase):
    """parse_epub_to_dict — iOS-friendly JSON shape used by PythonBridge."""

    FIXTURE = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    def test_returns_dict_with_wire_keys(self):
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE), book_id="abc123")
        self.assertIsInstance(payload, dict)
        for key in ("jobId", "bookTitle", "bookAuthor", "chapters"):
            self.assertIn(key, payload)
        self.assertEqual(payload["jobId"], "abc123")
        self.assertIsInstance(payload["chapters"], list)

    def test_chapter_shape_matches_swift_decoder(self):
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE))
        self.assertGreater(len(payload["chapters"]), 0)
        first = payload["chapters"][0]
        # Keys expected by EbookFulltext.Chapter (Swift Codable).
        for key in ("index", "name", "sourcePath", "text", "html", "css", "charCount", "segments"):
            self.assertIn(key, first)
        self.assertIn("speechText", first)
        self.assertIsInstance(first["index"], int)
        self.assertIsInstance(first["sourcePath"], str)
        self.assertIsInstance(first["text"], str)
        self.assertIsInstance(first["charCount"], int)
        self.assertEqual(first["charCount"], len(first["text"]))
        # html now mirrors the sanitized markup served by /fulltext; css stays
        # optional (only present when the chapter references a stylesheet).
        self.assertIsInstance(first["html"], str)
        self.assertGreater(len(first["html"]), 0)
        if first["css"] is not None:
            self.assertIsInstance(first["css"], str)
        self.assertIsNone(first["segments"])

    @patch.object(EpubParser, "parse")
    def test_parse_epub_to_dict_exposes_optional_canonical_speech_text(self, mock_parse):
        """The reader payload keeps visual text and canonical TTS text separate."""
        speech_text = "Chapter one...\n\nNarration with _inline markdown_."
        chapter = Chapter(
            index=1,
            name="Chapter one",
            source_path="ch1.xhtml",
            text="Reader text without the announced chapter title.",
            speech_text=speech_text,
        )
        mock_parse.return_value = Book("Book", "Author", [chapter])
        with tempfile.TemporaryDirectory() as tmp:
            epub_path = Path(tmp) / "book.epub"
            epub_path.write_text("dummy")
            payload = parse_epub_to_dict(str(epub_path))

        first = payload["chapters"][0]
        self.assertEqual(first["text"], "Reader text without the announced chapter title.")
        self.assertEqual(first["speechText"], speech_text)

    @patch.object(EpubParser, "parse")
    def test_parse_epub_to_dict_uses_null_for_missing_speech_text(self, mock_parse):
        """Older parser outputs remain decodable through the optional field."""
        chapter = Chapter(index=1, name="Ch1", source_path="ch1.xhtml", text="Reader text")
        mock_parse.return_value = Book("Book", "Author", [chapter])
        with tempfile.TemporaryDirectory() as tmp:
            epub_path = Path(tmp) / "book.epub"
            epub_path.write_text("dummy")
            payload = parse_epub_to_dict(str(epub_path))

        self.assertIsNone(payload["chapters"][0]["speechText"])

    @patch.object(EpubParser, "parse")
    def test_parse_epub_to_dict_emits_sanitized_html(self, mock_parse):
        raw_html = "<script>alert(1)</script><p>Hello <b>world</b></p>"
        chapter = Chapter(
            index=1, name="Ch1", source_path="ch1.xhtml", text="Hello world", raw_html=raw_html
        )
        mock_parse.return_value = Book("Book", "Author", [chapter])
        with tempfile.TemporaryDirectory() as tmp:
            epub_path = Path(tmp) / "book.epub"
            epub_path.write_text("dummy")
            payload = parse_epub_to_dict(str(epub_path))
        first = payload["chapters"][0]
        self.assertNotIn("<script", first["html"])
        self.assertIn("<b>world</b>", first["html"])
        self.assertEqual(first["text"], "Hello world")

    @patch.object(EpubParser, "parse")
    def test_parse_epub_to_dict_html_fallback_when_raw_html_absent(self, mock_parse):
        chapter = Chapter(index=1, name="Ch1", source_path="ch1.xhtml", text="Para one\n\nPara two")
        mock_parse.return_value = Book("Book", "Author", [chapter])
        with tempfile.TemporaryDirectory() as tmp:
            epub_path = Path(tmp) / "book.epub"
            epub_path.write_text("dummy")
            payload = parse_epub_to_dict(str(epub_path))
        first = payload["chapters"][0]
        self.assertEqual(first["html"].count("<p>"), 2)
        self.assertIsNone(first["css"])

    def _make_epub_with_toc_and_image(self) -> Path:
        """Real 2-chapter EPUB with an NCX TOC and one inline image, used to
        exercise `parse_epub_to_dict`'s `resources`/`toc` emission through
        the actual parser (not a mock) — `extract_chapter_resources` and the
        href→chapterIndex resolution both need a real zip archive to read
        from."""
        container_xml = b"""<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""
        opf = b"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-toc-resources</dc:identifier>
    <dc:title>TOC Resources Test</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>"""
        ncx = b"""<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-toc-resources"/></head>
  <docTitle><text>TOC Resources Test</text></docTitle>
  <navMap>
    <navPoint id="ch1" playOrder="1">
      <navLabel><text>Chapter One</text></navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
    <navPoint id="ch2" playOrder="2">
      <navLabel><text>Chapter Two</text></navLabel>
      <content src="chapter2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>"""
        chapter1 = b"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<body><h1>Chapter One</h1><p>Text with <img src="images/pic.png"/> an image.</p></body>
</html>"""
        chapter2 = b"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<body><h1>Chapter Two</h1><p>Second chapter text.</p></body>
</html>"""
        path = Path(tempfile.mkdtemp()) / "toc_resources.epub"
        with zipfile.ZipFile(path, "w") as zf:
            zf.writestr("mimetype", "application/epub+zip")
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("OEBPS/content.opf", opf)
            zf.writestr("OEBPS/toc.ncx", ncx)
            zf.writestr("OEBPS/chapter1.xhtml", chapter1)
            zf.writestr("OEBPS/chapter2.xhtml", chapter2)
            zf.writestr("OEBPS/images/pic.png", b"\x89PNG\r\n fake-png-bytes")
        return path

    def test_parse_epub_to_dict_emits_resources_and_resolved_toc(self):
        path = self._make_epub_with_toc_and_image()
        payload = parse_epub_to_dict(str(path))

        chapters = payload["chapters"]
        self.assertEqual(len(chapters), 2)
        self.assertEqual(chapters[0]["resources"][0]["href"], "images/pic.png")
        self.assertEqual(chapters[0]["sourcePath"], "OEBPS/chapter1.xhtml")
        self.assertEqual(chapters[0]["resources"][0]["mediaType"], "image/png")
        self.assertIsNone(chapters[1]["resources"])

        toc = payload["toc"]
        self.assertEqual(len(toc), 2)
        self.assertEqual(toc[0]["title"], "Chapter One")
        self.assertEqual(toc[0]["chapterIndex"], 1)
        self.assertEqual(toc[1]["title"], "Chapter Two")
        self.assertEqual(toc[1]["chapterIndex"], 2)

    @patch.object(EpubParser, "parse")
    def test_parse_epub_to_dict_toc_entry_with_no_matching_chapter_is_none(self, mock_parse):
        chapter = Chapter(index=1, name="Ch1", source_path="ch1.xhtml", text="Body text")
        book = Book(
            "Book",
            "Author",
            [chapter],
            toc=[TocItem(title="Orphan Note", href="endnotes.xhtml", level=1, children=[])],
        )
        mock_parse.return_value = book
        with tempfile.TemporaryDirectory() as tmp:
            epub_path = Path(tmp) / "book.epub"
            epub_path.write_text("dummy")
            payload = parse_epub_to_dict(str(epub_path))
        self.assertEqual(len(payload["toc"]), 1)
        self.assertIsNone(payload["toc"][0]["chapterIndex"])

    @patch.object(EpubParser, "parse")
    def test_parse_epub_to_dict_emits_footnotes_from_chapter(self, mock_parse):
        chapter = Chapter(
            index=1,
            name="Ch1",
            source_path="ch1.xhtml",
            text="Body text",
            footnotes=[{"number": "1", "text": "A footnote body."}],
        )
        mock_parse.return_value = Book("Book", "Author", [chapter])
        with tempfile.TemporaryDirectory() as tmp:
            epub_path = Path(tmp) / "book.epub"
            epub_path.write_text("dummy")
            payload = parse_epub_to_dict(str(epub_path))
        first = payload["chapters"][0]
        self.assertEqual(first["footnotes"], [{"number": "1", "text": "A footnote body."}])

    @patch.object(EpubParser, "parse")
    def test_parse_epub_to_dict_text_unchanged_by_html_addition(self, mock_parse):
        chapter = Chapter(
            index=1,
            name="Ch1",
            source_path="ch1.xhtml",
            text="  Plain text.  ",
            raw_html="<p>Plain text.</p>",
        )
        mock_parse.return_value = Book("Book", "Author", [chapter])
        with tempfile.TemporaryDirectory() as tmp:
            epub_path = Path(tmp) / "book.epub"
            epub_path.write_text("dummy")
            payload = parse_epub_to_dict(str(epub_path))
        first = payload["chapters"][0]
        self.assertEqual(first["text"], "Plain text.")
        self.assertEqual(first["charCount"], len("Plain text."))
        self.assertIsNotNone(first["html"])

    def test_empty_chapters_dropped_and_indices_compact(self):
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE))
        indices = [c["index"] for c in payload["chapters"]]
        self.assertEqual(indices, list(range(1, len(indices) + 1)))
        for chapter in payload["chapters"]:
            self.assertGreater(len(chapter["text"]), 0)

    def test_extract_chapter_resources_resolves_relative_percent_encoded_image(self):
        path = Path(tempfile.mkdtemp()) / "assets.epub"
        chapter_html = '<html><body><img src="../images/cover%20art.png"></body></html>'
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(
                "META-INF/container.xml",
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
            )
            archive.writestr(
                "OEBPS/content.opf",
                """<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="c" href="text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>""",
            )
            archive.writestr("OEBPS/text/chapter.xhtml", chapter_html)
            archive.writestr("OEBPS/images/cover art.png", b"png-bytes")
        chapter = Chapter(
            index=1,
            name="Ch",
            source_path="OEBPS/text/chapter.xhtml",
            text="x",
            raw_html=chapter_html,
        )
        resources = EbookReader(path).extract_chapter_resources(chapter)
        self.assertEqual(len(resources), 1)
        self.assertEqual(resources[0]["href"], "../images/cover%20art.png")
        self.assertEqual(resources[0]["mediaType"], "image/png")
        self.assertEqual(resources[0]["dataBase64"], "cG5nLWJ5dGVz")

    def test_extract_chapter_resources_includes_css_background_images(self):
        path = Path(tempfile.mkdtemp()) / "css-assets.epub"
        chapter_html = (
            '<html><head><link rel="stylesheet" href="../styles/book.css"></head>'
            '<body><p class="cover">Body</p></body></html>'
        )
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(
                "META-INF/container.xml",
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
            )
            archive.writestr(
                "OEBPS/content.opf",
                """<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="c" href="text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>""",
            )
            archive.writestr("OEBPS/text/chapter.xhtml", chapter_html)
            archive.writestr(
                "OEBPS/styles/book.css", ".cover { background-image: url('../images/bg.png'); }"
            )
            archive.writestr("OEBPS/images/bg.png", b"css-image")
        chapter = Chapter(
            index=1,
            name="Ch",
            source_path="OEBPS/text/chapter.xhtml",
            text="x",
            raw_html=chapter_html,
        )
        resources = EbookReader(path).extract_chapter_resources(chapter)
        self.assertEqual(len(resources), 1)
        self.assertEqual(resources[0]["href"], "../images/bg.png")
        self.assertEqual(resources[0]["dataBase64"], "Y3NzLWltYWdl")

    def test_extract_chapter_stylesheet_accepts_any_link_attribute_order(self):
        path = Path(tempfile.mkdtemp()) / "styles.epub"
        chapter_html = """
        <html><head>
          <link href="../styles/book.css" type="text/css" rel="stylesheet">
          <link rel="alternate stylesheet" href="../styles/ignored.css">
        </head><body><p class="atx">Body</p></body></html>
        """
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(
                "META-INF/container.xml",
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
            )
            archive.writestr(
                "OEBPS/content.opf",
                """<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="c" href="text/chapter.xhtml" media-type="application/xhtml+xml"/><item id="css" href="styles/book.css" media-type="text/css"/></manifest><spine><itemref idref="c"/></spine></package>""",
            )
            archive.writestr("OEBPS/text/chapter.xhtml", chapter_html)
            archive.writestr(
                "OEBPS/styles/book.css", ".atx { text-indent: 20pt; text-align: justify; }"
            )
            archive.writestr("OEBPS/styles/ignored.css", ".atx { text-indent: 0; }")
        chapter = Chapter(
            index=1,
            name="Ch",
            source_path="OEBPS/text/chapter.xhtml",
            text="Body",
            raw_html=chapter_html,
        )
        self.assertEqual(
            EbookReader(path).extract_chapter_stylesheet(chapter).strip(),
            ".atx { text-indent: 20pt; text-align: justify; }",
        )

    def test_json_roundtrip(self):
        """The dict must be JSON-serialisable — PythonBridge crosses
        the Swift boundary via json.dumps."""
        import json

        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE), book_id="x")
        encoded = json.dumps(payload)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["jobId"], "x")
        self.assertEqual(len(decoded["chapters"]), len(payload["chapters"]))


class TestHtmlFragmentToChaptersReusableAsStaticmethod(unittest.TestCase):
    """`_html_fragment_to_chapters` is the shared pipeline non-EPUB parsers
    (FB2, DOCX, MOBI) call directly — it must be usable with no `EpubParser`
    instance at all."""

    def test_callable_without_an_epubparser_instance(self):
        chapters = EpubParser._html_fragment_to_chapters(
            markup_with_markers="<p>Hello world.</p>",
            raw_content="<p>Hello world.</p>",
            chapter_idx=1,
            asset_path="section-1",
            toc_chapter_title="Chapter One",
            footnotes=None,
            cue_locale="en",
        )
        self.assertEqual(len(chapters), 1)
        self.assertEqual(chapters[0].name, "Chapter One")
        self.assertIn("Hello world.", chapters[0].text)

    def test_paragraph_split_chars_defaults_when_not_provided(self):
        long_text = "Sentence. " * 5000
        chapters = EpubParser._html_fragment_to_chapters(
            markup_with_markers=f"<p>{long_text}</p>",
            raw_content=f"<p>{long_text}</p>",
            chapter_idx=1,
            asset_path="section-1",
            toc_chapter_title="Long Chapter",
            footnotes=None,
            cue_locale="en",
        )
        # Should not crash and should produce at least one chapter even
        # without an explicit paragraph_split_chars (falls back to the
        # module default SUBCHAPTER_MAX_CHARS).
        self.assertGreaterEqual(len(chapters), 1)
