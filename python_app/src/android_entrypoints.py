"""Android entrypoints invoked from Kotlin via Chaquopy.

The Flutter Android app embeds CPython (via Chaquopy) and calls into these
functions over a Flutter MethodChannel bridge. The functions in this module
must return JSON-serializable strings so the Kotlin side can hand them
straight back to Dart without bespoke marshalling.

Mirrors the iOS PythonKit bridge (see ``ios/EpubToMp3/EpubToMp3/Services/
PythonBridge.swift``) but here we don't need a Swift-side network shim:
Chaquopy ships ``_socket`` and ``_ssl``, so ``aiohttp`` + ``edge_tts`` run
in-process unmodified.
"""

from __future__ import annotations

import json
from typing import Any, Dict, List

from .ebook_reader import Chapter, read_book


def _chapter_to_dict(chapter: Chapter) -> Dict[str, Any]:
    return {
        "index": chapter.index,
        "name": chapter.name or "",
        "text": chapter.text or "",
        "charCount": len(chapter.text or ""),
        "level": chapter.level,
    }


def parse_epub_to_dict(file_path: str) -> Dict[str, Any]:
    """Parse an EPUB/PDF and return a JSON-serializable dict.

    Shape matches ``flutter_app/lib/models/ebook_fulltext.dart``
    (camelCase keys, ``chapters`` is a list of ``FulltextChapter``).
    """
    book = read_book(file_path)
    chapters: List[Dict[str, Any]] = [_chapter_to_dict(ch) for ch in book.chapters]
    return {
        "jobId": "",  # Filled in by Dart side once the job exists
        "bookTitle": book.title or "",
        "bookAuthor": book.author or "",
        "chapters": chapters,
    }


def parse_epub_to_json(file_path: str) -> str:
    """Convenience wrapper: returns the JSON-encoded payload as a string.

    Chaquopy can return Python strings to Kotlin as ``String`` directly,
    which avoids any ``PyObject -> JSON`` conversion on the JVM side.
    """
    return json.dumps(parse_epub_to_dict(file_path), ensure_ascii=False)


def bootstrap() -> str:
    """Smoke-test the Python runtime is alive and importable.

    Returns the Python version string. Kotlin uses this to confirm the
    Chaquopy bundle finished initialising before the first real call.
    """
    import sys

    return sys.version


__all__ = ["bootstrap", "parse_epub_to_dict", "parse_epub_to_json"]
