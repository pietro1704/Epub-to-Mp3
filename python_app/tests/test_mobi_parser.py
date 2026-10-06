"""Tests for the MOBI/AZW3 parser (server/CLI only).

`mobi.extract` (third-party, KindleUnpack-based) is mocked throughout —
these tests validate this repo's integration glue (dispatch on its output
shape, tempdir cleanup, error wrapping), not the third-party library's own
unpacking correctness.
"""

import struct
import zipfile
from pathlib import Path
from unittest.mock import patch

import pytest
from src.ebook_reader import EbookReader
from src.mobi_drm import MobiDrmProtectedError
from src.mobi_parser import MobiParseError, MobiParser


def _make_mobi_header_bytes(encryption_type: int = 0) -> bytes:
    pdb_header = bytearray(78)
    pdb_header[60:68] = b"BOOKMOBI"
    struct.pack_into(">H", pdb_header, 76, 1)
    record0_offset = 78 + 8
    record_info = struct.pack(">I", record0_offset) + b"\x00\x00\x00\x00"
    record0 = bytearray(20)
    struct.pack_into(">H", record0, 12, encryption_type)
    return bytes(pdb_header) + record_info + bytes(record0)


def _make_stub_epub(tmp_path: Path) -> Path:
    """A minimal real EPUB so EpubParser has something valid to parse."""
    path = tmp_path / "extracted.epub"
    container_xml = b"""<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""
    opf = b"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">mobi-test</dc:identifier>
    <dc:title>From KF8</dc:title>
  </metadata>
  <manifest><item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="ch1"/></spine>
</package>"""
    chapter = b"<html><body><p>Chapter content from AZW3.</p></body></html>"
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("mimetype", "application/epub+zip")
        zf.writestr("META-INF/container.xml", container_xml)
        zf.writestr("OEBPS/content.opf", opf)
        zf.writestr("OEBPS/chapter1.xhtml", chapter)
    return path


def test_epub_shaped_output_reuses_epub_parser(tmp_path):
    stub_epub = _make_stub_epub(tmp_path)
    fake_source = tmp_path / "book.azw3"
    fake_source.write_bytes(b"fake-azw3-bytes")

    with patch("mobi.extract", return_value=(str(tmp_path), str(stub_epub))):
        book = MobiParser(fake_source).parse()

    assert book.title == "From KF8"
    assert len(book.chapters) == 1
    assert "Chapter content from AZW3." in book.chapters[0].text


def test_html_shaped_output_uses_shared_chapter_pipeline(tmp_path):
    html_dir = tmp_path / "mobi7"
    html_dir.mkdir()
    html_path = html_dir / "book.html"
    html_path.write_text("<p>Legacy MOBI7 content.</p>", encoding="utf-8")
    fake_source = tmp_path / "legacy.mobi"
    fake_source.write_bytes(b"fake-mobi7-bytes")

    with patch("mobi.extract", return_value=(str(tmp_path), str(html_path))):
        book = MobiParser(fake_source).parse()

    assert book.title == "legacy"
    assert len(book.chapters) == 1
    assert "Legacy MOBI7 content." in book.chapters[0].text


def test_unexpected_output_path_raises_mobi_parse_error(tmp_path):
    weird_path = tmp_path / "output.pdf"
    weird_path.write_bytes(b"not epub or html")
    fake_source = tmp_path / "book.mobi"
    fake_source.write_bytes(b"fake-bytes")

    with patch("mobi.extract", return_value=(str(tmp_path), str(weird_path))):
        with pytest.raises(MobiParseError):
            MobiParser(fake_source).parse()


def test_extract_failure_is_wrapped_as_mobi_parse_error(tmp_path):
    fake_source = tmp_path / "book.mobi"
    fake_source.write_bytes(b"fake-bytes")

    with patch("mobi.extract", side_effect=ValueError("Could not extract")):
        with pytest.raises(MobiParseError):
            MobiParser(fake_source).parse()


def test_tempdir_is_cleaned_up_even_on_error(tmp_path):
    tempdir_to_clean = tmp_path / "mobiex-fake"
    tempdir_to_clean.mkdir()
    (tempdir_to_clean / "leftover.tmp").write_text("junk")
    fake_source = tmp_path / "book.mobi"
    fake_source.write_bytes(b"fake-bytes")

    weird_path = tmp_path / "output.xyz"
    weird_path.write_bytes(b"unrecognized")

    with patch("mobi.extract", return_value=(str(tempdir_to_clean), str(weird_path))):
        with pytest.raises(MobiParseError):
            MobiParser(fake_source).parse()

    assert not tempdir_to_clean.exists()


def test_ebook_reader_rejects_drm_protected_mobi_before_extracting(tmp_path):
    protected = tmp_path / "protected.mobi"
    protected.write_bytes(_make_mobi_header_bytes(encryption_type=2))

    with patch("mobi.extract") as mock_extract:
        with pytest.raises(MobiDrmProtectedError):
            EbookReader(str(protected))
        mock_extract.assert_not_called()


def test_ebook_reader_dispatches_mobi_and_azw3_extensions(tmp_path):
    # Each iteration gets its own throwaway "extraction tempdir" — MobiParser
    # deletes whatever `mobi.extract` reports as the tempdir when done, so
    # reusing `tmp_path` itself here would wipe the test fixture out from
    # under the next iteration.
    for ext in ("mobi", "azw3", "azw", "prc"):
        extraction_dir = tmp_path / f"extract-{ext}"
        extraction_dir.mkdir()
        stub_epub = _make_stub_epub(extraction_dir)
        source = tmp_path / f"book.{ext}"
        source.write_bytes(_make_mobi_header_bytes(encryption_type=0))
        with patch("mobi.extract", return_value=(str(extraction_dir), str(stub_epub))):
            reader = EbookReader(str(source))
        assert reader.book is not None
        assert reader.book.title == "From KF8"
