"""Tests for CBR page ordering and shared image-resource extraction."""

from pathlib import Path
from unittest.mock import patch

from src.cbr_parser import CbrParser, read_page
from src.ebook_reader import EbookReader, parse_epub_to_dict


class _FakeRarFile:
    def __init__(self, path, mode="r"):
        self.path = Path(path)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def namelist(self):
        return ["page10.jpg", "page2.jpg", "cover.png", "notes.txt"]

    def read(self, member):
        return f"bytes:{member}".encode()


def test_cbr_parser_naturally_orders_image_pages(tmp_path):
    source = tmp_path / "comic.cbr"
    source.write_bytes(b"rar")

    with patch.dict("sys.modules", {"rarfile": type("RarModule", (), {"RarFile": _FakeRarFile})}):
        book = CbrParser(source).parse()

    assert [chapter.source_path for chapter in book.chapters] == [
        "cover.png",
        "page2.jpg",
        "page10.jpg",
    ]
    assert all(chapter.text == "" for chapter in book.chapters)


def test_cbr_reader_exposes_page_resources_and_image_content_kind(tmp_path):
    source = tmp_path / "comic.cbr"
    source.write_bytes(b"rar")

    fake_module = type("RarModule", (), {"RarFile": _FakeRarFile})
    with patch.dict("sys.modules", {"rarfile": fake_module}):
        reader = EbookReader(source)
        resource = reader.extract_chapter_resources(reader.book.chapters[0])
        payload = parse_epub_to_dict(source, "comic-id")

    assert resource[0]["mediaType"] == "image/png"
    assert resource[0]["dataBase64"]
    assert payload["chapters"][0]["contentKind"] == "images"
    assert len(payload["chapters"]) == 3


def test_cbr_cover_reads_first_page(tmp_path):
    source = tmp_path / "comic.cbr"
    source.write_bytes(b"rar")

    fake_module = type("RarModule", (), {"RarFile": _FakeRarFile})
    with patch.dict("sys.modules", {"rarfile": fake_module}):
        cover = EbookReader(source).extract_cover_image()

    assert cover is not None
    assert cover.media_type == "image/png"
    assert cover.extension == ".png"


def test_cbr_page_read_wraps_the_archive_contract(tmp_path):
    source = tmp_path / "comic.cbr"
    source.write_bytes(b"rar")

    fake_module = type("RarModule", (), {"RarFile": _FakeRarFile})
    with patch.dict("sys.modules", {"rarfile": fake_module}):
        data, media_type, extension = read_page(source, "page2.jpg")

    assert data == b"bytes:page2.jpg"
    assert media_type == "image/jpeg"
    assert extension == ".jpg"
