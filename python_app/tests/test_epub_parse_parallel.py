# -*- coding: utf-8 -*-
"""Verify parallel EPUB parsing preserves chapter ordering and content."""

from __future__ import annotations

import zipfile
from pathlib import Path

import pytest
from src.ebook_reader import EbookReader


def _make_epub(path: Path, n_chapters: int = 12) -> Path:
    """Create a minimal multi-spine EPUB with deterministic content."""
    container = (
        '<?xml version="1.0"?>'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>'
        "</container>"
    )
    manifest_items = "".join(
        f'<item id="ch{i}" href="ch{i}.xhtml" media-type="application/xhtml+xml"/>'
        for i in range(n_chapters)
    )
    spine_items = "".join(f'<itemref idref="ch{i}"/>' for i in range(n_chapters))
    opf = (
        '<?xml version="1.0"?>'
        '<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="bid">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:identifier id="bid">x</dc:identifier>'
        "<dc:title>Parallel Test</dc:title>"
        "<dc:language>en</dc:language>"
        "</metadata>"
        f"<manifest>{manifest_items}</manifest>"
        f"<spine>{spine_items}</spine>"
        "</package>"
    )
    epub_path = path / "parallel.epub"
    with zipfile.ZipFile(epub_path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("mimetype", "application/epub+zip")
        z.writestr("META-INF/container.xml", container)
        z.writestr("OEBPS/content.opf", opf)
        for i in range(n_chapters):
            body_text = f"Body text for spine item number {i}. " * 5
            body = f"<html><body><h1>Chapter Marker {i}</h1>" f"<p>{body_text}</p></body></html>"
            z.writestr(f"OEBPS/ch{i}.xhtml", body)
    return epub_path


@pytest.mark.parametrize("parallel", ["1", "0"])
def test_parallel_parsing_preserves_order_and_count(tmp_path, monkeypatch, parallel):
    epub_path = _make_epub(tmp_path, n_chapters=12)
    monkeypatch.setenv("EPUB_PARSE_PARALLEL", parallel)
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapters()
    assert len(chapters) == 12
    # Chapters must come back in spine order — verifiable from the marker
    # number embedded in each chapter's body.
    for expected_idx, ch in enumerate(chapters):
        assert f"item number {expected_idx}" in ch.text


def test_parallel_parsing_matches_sequential_output(tmp_path, monkeypatch):
    epub_path = _make_epub(tmp_path, n_chapters=10)

    monkeypatch.setenv("EPUB_PARSE_PARALLEL", "0")
    reader_seq = EbookReader(str(epub_path))
    seq = [(c.index, c.text) for c in reader_seq.get_chapters()]

    monkeypatch.setenv("EPUB_PARSE_PARALLEL", "1")
    reader_par = EbookReader(str(epub_path))
    par = [(c.index, c.text) for c in reader_par.get_chapters()]

    assert seq == par


def test_prepare_spine_item_skips_non_html(tmp_path):
    epub_path = _make_epub(tmp_path, n_chapters=2)
    # _prepare_spine_item lives on EpubParser; instantiate it directly.
    import threading

    from src.ebook_reader import EpubParser

    parser = EpubParser(str(epub_path))
    with zipfile.ZipFile(epub_path, "r") as zf:
        result = parser._prepare_spine_item(zf, threading.Lock(), "nonexistent_id", {}, "OEBPS")
    assert result is None
