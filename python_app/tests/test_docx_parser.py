"""Tests for the DOCX (Office Open XML) parser."""

import zipfile
from pathlib import Path

import pytest
from src.docx_parser import DocxParseError, DocxParser
from src.ebook_reader import EbookReader

_W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def _document_xml(body_xml: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f'<w:document xmlns:w="{_W}"><w:body>{body_xml}</w:body></w:document>'
    ).encode("utf-8")


def _p(
    text: str = "", *, bold: bool = False, italic: bool = False, heading: int | None = None
) -> str:
    rpr = ""
    if bold:
        rpr += "<w:b/>"
    if italic:
        rpr += "<w:i/>"
    run = (
        f"<w:r><w:rPr>{rpr}</w:rPr><w:t>{text}</w:t></w:r>"
        if rpr
        else f"<w:r><w:t>{text}</w:t></w:r>"
    )
    ppr = f'<w:pPr><w:pStyle w:val="Heading{heading}"/></w:pPr>' if heading else ""
    return f"<w:p>{ppr}{run}</w:p>"


def _make_docx(
    tmp_path: Path,
    body_xml: str,
    footnotes_xml: bytes | None = None,
    core_xml: bytes | None = None,
) -> Path:
    path = tmp_path / "doc.docx"
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("word/document.xml", _document_xml(body_xml))
        if footnotes_xml is not None:
            zf.writestr("word/footnotes.xml", footnotes_xml)
        if core_xml is not None:
            zf.writestr("docProps/core.xml", core_xml)
    return path


def test_paragraphs_become_a_single_chapter_without_headings(tmp_path):
    body = _p("First paragraph.") + _p("Second paragraph.")
    docx = _make_docx(tmp_path, body)

    book = DocxParser(docx).parse()

    assert len(book.chapters) == 1
    assert "First paragraph." in book.chapters[0].text
    assert "Second paragraph." in book.chapters[0].text


def test_heading1_splits_into_separate_chapters(tmp_path):
    body = (
        _p("Chapter One", heading=1)
        + _p("Body of chapter one.")
        + _p("Chapter Two", heading=1)
        + _p("Body of chapter two.")
    )
    docx = _make_docx(tmp_path, body)

    book = DocxParser(docx).parse()

    assert len(book.chapters) == 2
    assert book.chapters[0].name == "Chapter One"
    assert "Body of chapter one." in book.chapters[0].text
    assert book.chapters[1].name == "Chapter Two"
    assert "Body of chapter two." in book.chapters[1].text


def test_bold_and_italic_runs_preserved_in_raw_html(tmp_path):
    body = _p("bold text", bold=True) + _p("italic text", italic=True)
    docx = _make_docx(tmp_path, body)

    book = DocxParser(docx).parse()

    combined_html = "".join(ch.raw_html or "" for ch in book.chapters)
    assert "<b>bold text</b>" in combined_html
    assert "<i>italic text</i>" in combined_html


def test_heading2_renders_as_subheading_not_new_chapter(tmp_path):
    body = (
        _p("Chapter One", heading=1)
        + _p("Intro text.")
        + _p("A subheading", heading=2)
        + _p("More text.")
    )
    docx = _make_docx(tmp_path, body)

    book = DocxParser(docx).parse()

    assert len(book.chapters) == 1
    assert "<h2>A subheading</h2>" in (book.chapters[0].raw_html or "")


def test_footnotes_are_attached_to_chapter_but_not_lost(tmp_path):
    body = (
        _p("Chapter One", heading=1) + "<w:p><w:r><w:t>See this</w:t></w:r>"
        '<w:r><w:footnoteReference w:id="2"/></w:r></w:p>'
    )
    footnotes = (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f'<w:footnotes xmlns:w="{_W}">'
        f'<w:footnote w:id="0" w:type="separator"><w:p/></w:footnote>'
        f'<w:footnote w:id="2"><w:p><w:r><w:t>A footnote body.</w:t></w:r></w:p></w:footnote>'
        f"</w:footnotes>"
    ).encode("utf-8")
    docx = _make_docx(tmp_path, body, footnotes_xml=footnotes)

    book = DocxParser(docx).parse()

    assert len(book.chapters) == 1
    footnotes_out = book.chapters[0].footnotes
    assert footnotes_out is not None
    assert footnotes_out[0]["number"] == "2"
    assert footnotes_out[0]["text"] == "A footnote body."


def test_reads_title_and_author_from_core_properties(tmp_path):
    body = _p("Some text.")
    core = (
        b'<?xml version="1.0" encoding="UTF-8"?>'
        b"<cp:coreProperties "
        b'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        b'xmlns:dc="http://purl.org/dc/elements/1.1/">'
        b"<dc:title>My Document</dc:title>"
        b"<dc:creator>Jane Doe</dc:creator>"
        b"</cp:coreProperties>"
    )
    docx = _make_docx(tmp_path, body, core_xml=core)

    book = DocxParser(docx).parse()

    assert book.title == "My Document"
    assert book.author == "Jane Doe"


def test_missing_core_properties_falls_back_to_filename(tmp_path):
    docx = _make_docx(tmp_path, _p("Text."))

    book = DocxParser(docx).parse()

    assert book.title == "doc"
    assert book.author == ""


def test_corrupted_zip_raises_docx_parse_error(tmp_path):
    bad = tmp_path / "broken.docx"
    bad.write_bytes(b"not a zip file")

    with pytest.raises(DocxParseError):
        DocxParser(bad).parse()


def test_missing_document_xml_raises_docx_parse_error(tmp_path):
    path = tmp_path / "empty.docx"
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("README.txt", "not a real docx")

    with pytest.raises(DocxParseError):
        DocxParser(path).parse()


def test_ebook_reader_dispatches_docx_extension(tmp_path):
    docx = _make_docx(tmp_path, _p("Hello."))
    reader = EbookReader(str(docx))

    assert reader.book is not None
    assert len(reader.book.chapters) == 1
