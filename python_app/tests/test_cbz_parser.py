"""Tests for the CBZ (comic book zip) parser."""

import zipfile
from pathlib import Path

import pytest
from src.cbz_parser import CbzParseError, CbzParser
from src.ebook_reader import EbookReader, parse_epub_to_dict


def _make_cbz(tmp_path: Path, names_and_bytes: list[tuple[str, bytes]]) -> Path:
    path = tmp_path / "comic.cbz"
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in names_and_bytes:
            zf.writestr(name, data)
    return path


def test_pages_are_naturally_sorted_not_zip_order(tmp_path):
    # Written out of order and with unpadded numbers to exercise natural sort
    # (page2 must come before page10, not after it lexically).
    cbz = _make_cbz(
        tmp_path,
        [
            ("page10.jpg", b"page10"),
            ("page1.jpg", b"page1"),
            ("page2.jpg", b"page2"),
        ],
    )
    book = CbzParser(cbz).parse()

    assert [ch.source_path for ch in book.chapters] == ["page1.jpg", "page2.jpg", "page10.jpg"]
    assert [ch.name for ch in book.chapters] == ["Página 1", "Página 2", "Página 3"]
    assert all(ch.text == "" for ch in book.chapters)


def test_non_image_entries_are_ignored(tmp_path):
    cbz = _make_cbz(
        tmp_path,
        [
            ("page1.jpg", b"page1"),
            ("ComicInfo.xml", b"<ComicInfo/>"),
            ("thumbs.db", b"junk"),
        ],
    )
    book = CbzParser(cbz).parse()

    assert len(book.chapters) == 1
    assert book.chapters[0].source_path == "page1.jpg"


def test_corrupted_zip_raises_cbz_parse_error(tmp_path):
    bad = tmp_path / "broken.cbz"
    bad.write_bytes(b"not a zip file")

    with pytest.raises(CbzParseError):
        CbzParser(bad).parse()


def test_ebook_reader_dispatches_cbz_extension(tmp_path):
    cbz = _make_cbz(tmp_path, [("page1.jpg", b"page1")])
    reader = EbookReader(str(cbz))

    assert reader.book is not None
    assert len(reader.book.chapters) == 1


def test_extract_chapter_resources_reads_page_bytes_for_cbz(tmp_path):
    cbz = _make_cbz(tmp_path, [("page1.jpg", b"\xff\xd8\xff\xe0fake-jpeg-bytes")])
    reader = EbookReader(str(cbz))

    resources = reader.extract_chapter_resources(reader.book.chapters[0])

    assert len(resources) == 1
    assert resources[0]["href"] == "page1.jpg"
    assert resources[0]["mediaType"] == "image/jpeg"


def test_extract_cover_image_uses_first_page(tmp_path):
    cbz = _make_cbz(
        tmp_path, [("page1.jpg", b"\xff\xd8\xff\xe0cover-bytes"), ("page2.jpg", b"other")]
    )
    reader = EbookReader(str(cbz))

    cover = reader.extract_cover_image()

    assert cover is not None
    assert cover.data == b"\xff\xd8\xff\xe0cover-bytes"
    assert cover.media_type == "image/jpeg"


def test_parse_epub_to_dict_keeps_empty_text_chapters_for_cbz(tmp_path):
    cbz = _make_cbz(
        tmp_path, [("page1.jpg", b"\xff\xd8\xff\xe0one"), ("page2.jpg", b"\xff\xd8\xff\xe0two")]
    )
    payload = parse_epub_to_dict(str(cbz))

    assert len(payload["chapters"]) == 2
    for chapter in payload["chapters"]:
        assert chapter["contentKind"] == "images"
        assert chapter["text"] == ""
        assert chapter["resources"] is not None
        assert chapter["html"] is None


def test_parse_epub_to_dict_marks_text_formats_as_content_kind_text(tmp_path):
    # Reuse the existing FB2 fixture to confirm text-based formats still
    # report "text" (not omitted / not "images").
    fb2_fixture = Path(__file__).parent / "fixtures" / "fb2" / "sample.fb2"
    payload = parse_epub_to_dict(str(fb2_fixture))

    assert len(payload["chapters"]) > 0
    for chapter in payload["chapters"]:
        assert chapter["contentKind"] == "text"
