# -*- coding: utf-8 -*-
"""Regression tests for orphan chapter preservation.

Chapters that exist in the EPUB spine but lack a TOC entry (dedicatórias,
epigraphs, copyright pages) must NOT be silently dropped during structure
generation.  This was a real bug: books like "O Louco de Deus" lost 3
chapters (dedicatória, two epigraphs — 639 chars of real content).
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest


def _make_chapter(index, name, text, source_path="OEBPS/ch.xhtml"):
    """Create a minimal Chapter-like object."""
    return SimpleNamespace(
        index=index,
        name=name,
        text=text,
        speech_text=text,
        raw_html=f"<p>{text}</p>",
        source_path=source_path,
        formatting_segments=[],
        footnotes=[],
        toc_level=None,
    )


class TestShouldSkipChapter:
    """Tests for ConverterApplication._should_skip_chapter."""

    @pytest.fixture()
    def app(self):
        from python_app.main import ConverterApplication

        inst = ConverterApplication.__new__(ConverterApplication)
        from python_app.src.i18n import get_localization

        inst.localization = get_localization("en")
        inst.language_profile = None
        inst._metadata_display_language = None
        return inst

    def test_empty_text_skipped(self, app):
        chapters = [_make_chapter(1, "Empty", "")]
        assert app._should_skip_chapter(chapters, 0, {}) is True

    def test_very_short_text_skipped(self, app):
        chapters = [_make_chapter(1, "Short", "Hello world")]
        assert app._should_skip_chapter(chapters, 0, {}) is True

    def test_dedicatoria_74_chars_not_skipped(self, app):
        """Dedicatória (74 chars, no TOC entry) must NOT be dropped."""
        text = "Para Blanca Mena Martínez, com toda a certeza\nPara Raúl Cercas e Mercè Mas"
        chapters = [_make_chapter(1, "Dedicatória", text)]
        assert len(text) == 74
        assert app._should_skip_chapter(chapters, 0, {}) is False

    def test_epigraph_81_chars_not_skipped(self, app):
        """Epigraph (81 chars, no TOC entry) must NOT be dropped."""
        text = "Além da derrota existe uma vitória da qual o vencedor nada sabe.\nWilliam Faulkner"
        chapters = [_make_chapter(1, "Epígrafe", text)]
        assert len(text) == 81
        assert app._should_skip_chapter(chapters, 0, {}) is False

    def test_epigraph_484_chars_not_skipped(self, app):
        """Large epigraph (484 chars, no TOC entry) must NOT be dropped."""
        text = "Sou ateu. " * 48 + "Aqui."  # ~485 chars
        chapters = [_make_chapter(1, "Epígrafe", text)]
        assert len(text) > 400
        assert app._should_skip_chapter(chapters, 0, {}) is False

    def test_chapter_with_toc_entry_never_skipped(self, app):
        """Chapter with a TOC entry is never skipped, even if short."""
        chapters = [_make_chapter(1, "Ch1", "Hi", source_path="OEBPS/ch1.xhtml")]
        toc_map = {"oebps/ch1.xhtml": [(1, "Ch1", None)]}
        assert app._should_skip_chapter(chapters, 0, toc_map) is False
