"""Tests for the FictionBook 2.0 (.fb2) parser."""

from pathlib import Path

import pytest
from src.ebook_reader import EbookReader
from src.fb2_parser import Fb2ParseError, Fb2Parser

FIXTURE = Path(__file__).parent / "fixtures" / "fb2" / "sample.fb2"


def test_parses_title_author_and_language():
    book = Fb2Parser(FIXTURE).parse()

    assert book.title == "Sample FB2 Book"
    assert book.author == "Ada Lovelace"
    assert book.language == "en"


def test_nested_sections_produce_separate_chapters_with_hierarchical_toc():
    book = Fb2Parser(FIXTURE).parse()

    names = [ch.name for ch in book.chapters]
    assert "Chapter One" in names
    assert "Chapter Two" in names
    # "Part One" has only a <title> (no <p> body) but that heading text is
    # still non-empty, so it becomes its own thin chapter alongside its two
    # nested chapters — matches how EPUB handles part-divider pages.
    assert "Part One" in names
    assert len(book.chapters) == 3

    assert len(book.toc) == 1
    part = book.toc[0]
    assert part.title == "Part One"
    assert part.level == 1
    assert len(part.children) == 2
    assert part.children[0].title == "Chapter One"
    assert part.children[0].level == 2


def test_inline_emphasis_and_strong_preserved_in_raw_html():
    book = Fb2Parser(FIXTURE).parse()

    chapter_one = next(ch for ch in book.chapters if ch.name == "Chapter One")
    assert "<i>italic</i>" in chapter_one.raw_html
    assert "<b>bold</b>" in chapter_one.raw_html
    assert "italic" in chapter_one.text
    assert "bold" in chapter_one.text


def test_notes_body_is_not_treated_as_chapter_content():
    book = Fb2Parser(FIXTURE).parse()

    assert not any("Footnote body content" in ch.text for ch in book.chapters)


def test_ebook_reader_dispatches_fb2_extension():
    reader = EbookReader(str(FIXTURE))

    assert reader.book is not None
    assert reader.book.title == "Sample FB2 Book"


def test_invalid_xml_raises_fb2_parse_error(tmp_path):
    bad_file = tmp_path / "broken.fb2"
    bad_file.write_text("<FictionBook><unclosed>", encoding="utf-8")

    with pytest.raises(Fb2ParseError):
        Fb2Parser(bad_file).parse()


def test_missing_title_info_falls_back_to_filename(tmp_path):
    minimal = tmp_path / "untitled.fb2"
    minimal.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
        "<body><section><p>Just text.</p></section></body>"
        "</FictionBook>",
        encoding="utf-8",
    )

    book = Fb2Parser(minimal).parse()

    assert book.title == "untitled"
    assert len(book.chapters) == 1
    assert "Just text." in book.chapters[0].text
