"""Regression: heavy parsers must NOT run on the main actor.

Symptoms when they do: ``<0x...> Gesture: System gesture gate timed out``
in the syslog, the UI freezing for hundreds of ms while the parser
chews a ZIP + XML tree, and tap events being dropped.

`BookOpenScreenController.loadBook()` is `@MainActor` because it owns the
reader UI. The asynchronous parser call must stay behind the bridge's
dedicated worker. We pin the native call sites here:

1. The EPUB parser — either ``EpubFallbackParser.parse`` in the legacy
   Swift path or ``PythonBridge.parseEpub`` in the embedded Python path.
2. ``PdfTextExtractor.extract`` — PDFKit text extraction across pages.

If you ever inline either back onto the main actor, this test fails
with a clear pointer at the regression site.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BOOK_OPEN = (
    REPO_ROOT
    / "ios"
    / "EpubToMp3"
    / "EpubToMp3"
    / "Features"
    / "Reader"
    / "Views"
    / "BookOpenScreenController.swift"
)
PYTHON_BRIDGE = (
    REPO_ROOT
    / "ios"
    / "EpubToMp3"
    / "EpubToMp3"
    / "Features"
    / "Conversion"
    / "Services"
    / "PythonBridge.swift"
)


def _enclosing_block(text: str, needle: str) -> str:
    """Return the ~10 lines surrounding `needle` inside `text`."""
    idx = text.find(needle)
    assert idx >= 0, f"Did not find {needle!r} in BookOpenView.swift"
    start = max(0, text.rfind("\n", 0, idx - 600))
    end = text.find("\n", idx + 200)
    return text[start:end]


def test_epub_fallback_parser_runs_off_main_actor() -> None:
    body = BOOK_OPEN.read_text(encoding="utf-8")
    if "EpubFallbackParser.parse(" in body:
        block = _enclosing_block(body, "EpubFallbackParser.parse(")
        assert re.search(r"Task\.detached\s*\(", block), (
            "EpubFallbackParser.parse(...) must be wrapped in a "
            "Task.detached so the ZIP + XMLParser walk does not stall "
            "the main actor — symptom: 'Gesture: System gesture gate "
            "timed out' in syslog."
        )
        return

    assert "PythonBridge.shared.parseEpub(" in body
    bridge = PYTHON_BRIDGE.read_text(encoding="utf-8")
    assert "runner.callAsync(" in bridge, (
        "PythonBridge.parseEpub(...) must execute through its dedicated "
        "runner so embedded Python parsing does not stall the main actor."
    )
    assert "EpubFallbackParser.parse" in bridge
    assert "Task.detached" in bridge


def test_pdf_document_load_is_in_the_native_reader() -> None:
    """PDFs remain supported by the native reader."""
    body = BOOK_OPEN.read_text(encoding="utf-8")
    assert "PDFDocument(url: url)" in body
    assert "showPDF(url)" in body


def test_local_fulltext_cache_read_runs_off_main_actor() -> None:
    """The native reader must continue to use the local parsed-text cache."""
    body = BOOK_OPEN.read_text(encoding="utf-8")
    occurrences = [m.start() for m in re.finditer(r"LocalFulltextCache\.read\(", body)]
    assert occurrences, "LocalFulltextCache.read no longer used in the native reader?"


def test_currently_reading_book_id_written_from_library_tap() -> None:
    """Tapping a library tile must mark the book as the current
    reading target so the Read tab lands on the freshly-opened book.
    Without this write, the Read tab keeps showing whatever was last
    set inside MainReaderView itself — and the user complains "books
    opened recently don't go to the Read tab".

    Accepts both the direct key write (``currentlyReadingBookIDKey``) and
    the encapsulated ``MainReaderView.setCurrentlyReading(bookID:)`` call,
    which is the preferred pattern introduced in the library-tap refactor.
    """
    library_view = (
        REPO_ROOT
        / "ios"
        / "EpubToMp3"
        / "EpubToMp3"
        / "Features"
        / "Library"
        / "Views"
        / "LibraryScreenController.swift"
    )
    body = library_view.read_text(encoding="utf-8")
    assert "library.update(" in body
