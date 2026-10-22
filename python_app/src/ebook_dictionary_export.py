# -*- coding: utf-8 -*-
"""Legacy EPUB dictionary export compatibility."""

from __future__ import annotations

from typing import List, Optional

from .ebook_models import TocItem


def parse_epub_to_dict(file_path: str, book_id: str = "") -> dict:
    """iOS-friendly serialisation of a parsed Book.

    Returns a plain dict whose shape matches the wire contract of
    ``GET /api/jobs/{id}/fulltext`` (see ``EbookFulltext.swift``), so the
    SwiftUI client can ``JSONDecoder().decode(EbookFulltext.self, ...)``
    the result with no adapter layer.

    Used by the in-process Python embed on iOS (``PythonBridge.swift``)
    to share the canonical parser with the macOS sidecar and HF Spaces
    backend instead of maintaining a parallel Swift implementation
    (``LocalEpubParser.swift``, removed).

    Drops zero-length chapters; ``charCount`` reflects only ``text``.
    ``html``/``css`` mirror the sanitized markup served by
    ``GET /api/jobs/{id}/fulltext`` (falling back to a plain paragraph wrap
    of ``text`` when a chapter has no captured ``raw_html``, e.g. PDF
    sources). ``segments`` remains ``None`` — no on-device path populates
    per-sentence timing yet. ``resources`` carries bounded inline images;
    ``footnotes`` carries the ``{number, text}`` pairs already extracted by
    the speech pipeline. ``toc`` mirrors ``EbookReader.get_toc()`` with each
    entry's ``href`` pre-resolved to the compacted ``chapters[].index`` (the
    client never needs to match a raw href against a chapter path).
    ``contentKind`` is ``"images"`` for CBZ/CBR (one page image per chapter,
    via ``resources``, ``text`` intentionally empty and not dropped) and
    ``"text"`` for every other format — the client uses it to decide
    whether to render a text chapter or an image page, and to disable
    TTS conversion for image-only books.
    """
    from . import ebook_reader as _runtime
    reader = _runtime.EbookReader(file_path)
    if not reader.book:
        raise RuntimeError("Failed to read book")
    book = reader.book
    # CBZ chapters are legitimately textless (one page image each) — the
    # empty-text drop below only applies to text-based formats, where an
    # empty chapter really is content-free (cover pages, blank separators).
    is_image_only = reader.file_path is not None and reader.file_path.suffix.lower() in {
        ".cbz",
        ".cbr",
    }
    content_kind = "images" if is_image_only else "text"
    chapters: list[dict] = []
    source_path_to_index: dict[str, int] = {}
    out_index = 1
    for chapter in book.chapters:
        text = (chapter.text or "").strip()
        if not text and not is_image_only:
            continue
        try:
            resources = reader.extract_chapter_resources(chapter)
        except Exception:
            resources = []
        if is_image_only:
            html_raw = None
            css_raw = ""
        else:
            html_raw = _runtime.sanitize_reader_html((chapter.raw_html or "").strip())
            if not html_raw:
                html_raw = _runtime.sanitize_reader_html(_runtime.chapter_html_fallback(text))
            try:
                css_raw = _runtime.sanitize_reader_css(reader.extract_chapter_stylesheet(chapter))
            except Exception:
                css_raw = ""
        footnotes = list(chapter.footnotes) if chapter.footnotes else None
        # ``speech_text`` is the canonical TTS payload prepared during parsing.
        # Keep the reader-facing ``text`` untouched and expose the audio-specific
        # value separately so older clients can continue decoding the payload.
        speech_text = (chapter.speech_text or "").strip() or None
        chapters.append(
            {
                "index": out_index,
                "name": chapter.name,
                "sourcePath": chapter.source_path or None,
                "text": text,
                "speechText": speech_text,
                "html": html_raw or None,
                "css": css_raw or None,
                "charCount": len(text),
                "segments": None,
                "resources": resources or None,
                "footnotes": footnotes,
                "contentKind": content_kind,
            }
        )
        source_path = (chapter.source_path or "").split("#", 1)[0].strip()
        if source_path and source_path not in source_path_to_index:
            source_path_to_index[source_path] = out_index
        out_index += 1

    def resolve_chapter_index(href: str) -> Optional[int]:
        """Match a TOC entry's href against `source_path_to_index`.

        `TocItem.href` (read from the NCX/nav `content src=...`) is
        relative to the OPF directory, while `Chapter.source_path` is
        zip-root-relative (e.g. "OEBPS/chapter1.xhtml" vs.
        "chapter1.xhtml") — the two conventions don't share a common
        prefix, so an exact-match lookup silently drops every TOC
        resolution. Fall back to a suffix match (`.../href`) before
        giving up.
        """
        if not href:
            return None
        if href in source_path_to_index:
            return source_path_to_index[href]
        for candidate, idx in source_path_to_index.items():
            if candidate == href or candidate.endswith("/" + href):
                return idx
        return None

    def resolve_toc(items: List["TocItem"]) -> list[dict]:
        entries: list[dict] = []
        for item in items:
            href = (item.href or "").split("#", 1)[0].strip()
            entries.append(
                {
                    "title": item.title,
                    "level": item.level,
                    "chapterIndex": resolve_chapter_index(href),
                    "children": resolve_toc(item.children),
                }
            )
        return entries

    toc = resolve_toc(book.toc) if book.toc else None

    return {
        "jobId": book_id,
        "bookTitle": book.title,
        "bookAuthor": book.author,
        "chapters": chapters,
        "toc": toc,
    }
