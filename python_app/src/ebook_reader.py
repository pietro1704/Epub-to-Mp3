# -*- coding: utf-8 -*-
"""Lightweight EPUB/PDF reader used across the simplified test-suite."""

from __future__ import annotations

import base64 as base64
import html as html
import json as json
import os as _shared_os
import posixpath as posixpath
import re
import threading
import time as time
from collections import OrderedDict

try:
    import zipfile
except ImportError:
    zipfile = None  # type: ignore[assignment]
from dataclasses import dataclass as dataclass
from dataclasses import field as field
from html.parser import HTMLParser as HTMLParser
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from typing import Any as Any
from typing import Iterable as Iterable

try:
    import hashlib
except ImportError:
    hashlib = None  # type: ignore[assignment]

try:
    import mimetypes
except ImportError:
    mimetypes = None  # type: ignore[assignment]

try:
    from urllib.parse import unquote
except ImportError:

    def unquote(s: str, encoding: str = "utf-8", errors: str = "replace") -> str:
        parts = s.split("%")
        if len(parts) == 1:
            return s
        result = [parts[0]]
        for item in parts[1:]:
            try:
                result.append(bytes.fromhex(item[:2]).decode(encoding, errors) + item[2:])
            except (ValueError, UnicodeDecodeError):
                result.append("%" + item)
        return "".join(result)


from xml.etree import ElementTree as ET  # noqa: F401 - extracted methods use the facade namespace

from .cache_manager import CacheManager as CacheManager
from .ebook_dictionary_export import parse_epub_to_dict as parse_epub_to_dict
from .ebook_footnote_markup import FootnoteMarkupCollection
from .ebook_footnote_rendering import FootnoteRendering
from .ebook_html_text import HtmlTextExtraction
from .ebook_models import Book as Book
from .ebook_models import Chapter as Chapter
from .ebook_models import CoverImage as CoverImage
from .ebook_models import TocItem as TocItem
from .ebook_pdf_parser import PdfParser as PdfParser
from .ebook_resources import EbookResources
from .ebook_structural_speech import StructuralSpeechPreparation
from .ebook_toc_cache import _toc_cache_get as _toc_cache_get
from .ebook_toc_cache import _toc_cache_put as _toc_cache_put
from .ebook_toc_cache import _toc_disk_cache_cleanup as _toc_disk_cache_cleanup
from .ebook_toc_cache import _toc_disk_cache_path as _toc_disk_cache_path
from .ebook_toc_cache import _toc_from_jsonable as _toc_from_jsonable
from .ebook_toc_cache import _toc_to_jsonable as _toc_to_jsonable
from .epub_chapter_assembly import EpubChapterAssembly
from .epub_content_integrity import EpubContentIntegrity
from .epub_metadata import EpubMetadata
from .epub_navigation import EpubNavigation
from .epub_subchapter_splitting import EpubSubchapterSplitting
from .epub_toc_chapters import EpubTocChapters
from .pdf_scan_ocr import PdfOcrPage as PdfOcrPage
from .pdf_scan_ocr import PdfScanOcr as PdfScanOcr
from .reader_sanitizer import chapter_html_fallback as chapter_html_fallback
from .reader_sanitizer import sanitize_reader_css as sanitize_reader_css
from .reader_sanitizer import sanitize_reader_html as sanitize_reader_html
from .text_formatting import FormattingSegment as FormattingSegment
from .text_formatting import TextFormattingProcessor as TextFormattingProcessor

os = _shared_os

try:  # pragma: no cover - exercised indirectly in tests
    import pypdf  # type: ignore

    PDF_AVAILABLE = True
except ImportError:  # pragma: no cover - when pypdf is missing
    pypdf = None
    PDF_AVAILABLE = False

# Public regular expressions expected by the tests ---------------------------------
TAG_RE = re.compile(r"<[^>]+>")
WHITESPACE_RE = re.compile(r"[ \t\f\v]+")
NBSP_RE = re.compile(r"(?:&nbsp;|\u00A0)", re.I)
PARA_BLOCK_RE = re.compile(
    r"</?(p|div|br|li|tr|td|th|blockquote|section|article|hr|h[1-6])[^>]*>", re.I
)
ARTIFACT_RE = re.compile(r"\b(?:[\w\-/]+\.(?:xhtml|html|opf|ncx|css)|\d+_[\w-]+)\b", re.I)
H_TAG = re.compile(r"<h([1-6])[^>]*>(.*?)</h\1>", re.I | re.DOTALL)
PAGE_BREAK_RE = re.compile(
    r"page-break-before\s*:\s*always|page-break-after\s*:\s*always|break-before\s*:\s*page|break-after\s*:\s*page",
    re.I,
)

# CSS class names (matched as substrings) for section-number paragraphs that
# open a new subchapter block.  The split point is the number element; the
# title is taken from the immediately following SUBCHAPTER_TITLE_CLASS element.
#   class_s3P-0 → first section in a chapter  (e.g. "1" in IT ch.11)
#   class_s42-0 → subsequent sections          (e.g. "2", "3" … in IT ch.11)
# Add more names here for other conversion tool artefacts.
SUBCHAPTER_NUMBER_CLASSES: frozenset = frozenset({"class_s3P-0", "class_s42-0"})

# CSS class name of the title paragraph that immediately follows a section-
# number paragraph.  Its text content becomes the sub-chapter name
# (e.g. "Ben Hanscom faz uma retirada").
SUBCHAPTER_TITLE_CLASS: str = "class_sG5"


# Plain-text character threshold above which a chapter is split at paragraph
# boundaries to prevent Edge-TTS timeout on very large chapters.
# Computed at import time from Edge env vars so the threshold scales with
# the runtime concurrency profile (e.g. HF vs local).
# Formula: max(EDGE_CHUNK_CHARS × EDGE_MAX_CONCURRENCY × 2, 20_000)
#   local  (concurrency=12): 12_000 × 12 × 2 = 288_000  → rarely splits
#   HF     (concurrency=1 ): 12_000 ×  1 × 2 =  24_000  → splits large chapters
def _default_split_chars() -> int:
    import os

    chunk = max(int(os.getenv("EDGE_CHUNK_CHARS", 12_000)), 1_000)
    concurrency = max(int(os.getenv("EDGE_MAX_CONCURRENCY", 12)), 1)
    return max(chunk * concurrency * 2, 20_000)


SUBCHAPTER_MAX_CHARS: int = _default_split_chars()

XML_NS = {
    "ocf": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
}


# Locale-keyed footnote label phrases used by _render_footnotes /
# _apply_footnotes_to_segments.  Add a new locale key to extend support.
# The default in those methods falls back to "pt" if the key is missing;
# always provide at least "en" and "pt".
_FOOTNOTE_PHRASES: Dict[str, Dict[str, str]] = {
    "pt": {
        "prefix": "\n\n",
        "template": "nota de rodapé {number}...\n{text}",
        "suffix_text": "\nfim da nota de rodapé...",
        "closing": "\n\n",
        "chapter_end_template": (
            "nota de rodapé {number}...\n{snippet} — {text}\nfim da nota de rodapé..."
        ),
    },
    "en": {
        "prefix": "\n\n",
        "template": "footnote {number}...\n{text}",
        "suffix_text": "\nend of footnote...",
        "closing": "\n\n",
        "chapter_end_template": ("footnote {number}...\n{snippet} — {text}\nend of footnote..."),
    },
}


def _footnote_phrases_for_locale(cue_locale: str) -> Dict[str, str]:
    """Return the footnote label phrases dict for *cue_locale*.

    Falls back to 'en' when the locale is not explicitly mapped so that any
    non-Portuguese book gets English labels instead of the Portuguese defaults
    that were previously hard-coded in _render_footnotes / _apply_footnotes_to_segments.
    """
    root = (cue_locale or "en").split("-")[0].lower()
    return _FOOTNOTE_PHRASES.get(root) or _FOOTNOTE_PHRASES["en"]


class TextProcessor(
    HtmlTextExtraction,
    FootnoteMarkupCollection,
    FootnoteRendering,
    StructuralSpeechPreparation,
):
    """Utility helpers for dealing with HTML text inside EPUB files."""


    # Per-process cache for ``inject_footnotes`` results. Keyed on a sha1
    # of the raw markup. Bounded so pathological corpora don't grow it
    # unboundedly. Skipped when ``external_file_resolver`` is set: an
    # external resolver can produce different outputs across runs (it
    # walks the zip), so caching by markup alone would be unsound.
    _FOOTNOTE_CACHE_LIMIT = 256
    _footnote_cache: "Dict[str, Tuple[str, List[Dict[str, str]]]]" = {}
    _footnote_cache_lock = threading.Lock()

    @classmethod
    def clear_footnote_cache(cls) -> None:
        """Drop the per-process inject_footnotes memo. Mirrors
        ``LanguageDetector.clear_cache`` for parity — useful between CI
        runs and for test hygiene."""
        with cls._footnote_cache_lock:
            cls._footnote_cache.clear()


_TOC_CACHE_MAX = 16
_toc_cache: "OrderedDict[Tuple[str, int, str], List[TocItem]]" = OrderedDict()


_TOC_DISK_CACHE_CLEANED: bool = False


# Regex patterns that identify a spine file as a pure endnote / footnote
# container that should be excluded from the chapter list.  The patterns
# match EPUB3 ARIA roles and epub:type values used by publishers to annotate
# footnote-body sections (e.g. Hobbit_note_N.xhtml in HarperCollins 75th-ann.
# edition).
_ENDNOTE_ROLE_RE = re.compile(
    r"""role\s*=\s*["'](?:[^"']*\s+)?doc-endnotes(?:\s+[^"']*)?\s*["']""",
    re.IGNORECASE,
)
_ENDNOTE_EPUBTYPE_RE = re.compile(
    r"""epub:type\s*=\s*["'][^"']*\bendnotes\b[^"']*["']""",
    re.IGNORECASE,
)

# Maximum number of characters after the opening <body> tag within which an
# endnote annotation must appear to be considered a "top-level" container.
# Chapters that happen to include a <section epub:type="footnotes"> at the end
# will have this marker far later in the file and are NOT classified as
# endnote containers.
_ENDNOTE_BODY_PROXIMITY = 200


def _is_endnote_container(raw_html: str) -> bool:
    """Return True when *raw_html* is a standalone endnote/footnote container.

    A file is an endnote container only when the endnote ARIA role
    (``role="doc-endnotes"``) or epub:type (``epub:type="endnotes"``) appears
    as the **first structural child of <body>** — i.e. within
    ``_ENDNOTE_BODY_PROXIMITY`` characters after the opening ``<body>`` tag.

    Chapters that embed a small ``<section epub:type="footnotes">`` at the end
    of their prose have the annotation hundreds of characters into the body and
    are NOT classified as endnote containers.  Only files where the *entire*
    content is a footnote body trigger this guard.
    """
    body_start = raw_html.lower().find("<body")
    if body_start == -1:
        return False
    # Inspect only the narrow window immediately after <body>
    window_end = body_start + _ENDNOTE_BODY_PROXIMITY + 50  # +50 for the tag itself
    window = raw_html[body_start:window_end]
    return bool(_ENDNOTE_ROLE_RE.search(window)) or bool(_ENDNOTE_EPUBTYPE_RE.search(window))


class EpubParser(
    EpubMetadata,
    EpubTocChapters,
    EpubSubchapterSplitting,
    EpubChapterAssembly,
    EpubContentIntegrity,
    EpubNavigation,
):
    """Parse a single EPUB file into a :class:`Book` instance."""

    def __init__(
        self,
        file_path: str | Path,
        paragraph_split_chars: int = 0,
    ) -> None:
        self.file_path = str(file_path)
        self.path = Path(file_path)
        # 0 means "use SUBCHAPTER_MAX_CHARS default computed from env vars"
        self.paragraph_split_chars = paragraph_split_chars or SUBCHAPTER_MAX_CHARS


    def parse(self) -> Book:
        with zipfile.ZipFile(self.path, "r") as archive:
            opf_path = self._find_opf_path(archive)
            manifest, spine_ids, title, author, language = self._parse_opf(archive, opf_path)
            base_dir = self._opf_dir(opf_path)
            toc = self._parse_toc(archive, base_dir, opf_path=opf_path)
            toc_title_map = self._build_toc_title_map(toc, base_dir)

            # Use spine-based method (reliable, preserves all content)
            chapters = self._extract_chapters(
                archive,
                manifest,
                spine_ids,
                base_dir,
                toc_title_map=toc_title_map,
                toc=toc,
                book_language=language,
            )

        # Assign hierarchy levels from TOC so callers can distinguish
        # top-level parts (level=1) from subchapters (level=2, 3, …).
        self._assign_levels_from_toc(chapters, toc, base_dir)

        title = title or self.path.stem
        author = author or ""
        return Book(
            title=title.strip(),
            author=author.strip(),
            chapters=chapters,
            toc=toc,
            language=language,
        )


class EbookReader(
    EbookResources,
):
    """Facade used by the rest of the code base."""

    def __init__(
        self,
        file_path: Optional[str | Path] = None,
        paragraph_split_chars: int = 0,
    ) -> None:
        self.file_path: Optional[Path] = None
        self.book: Optional[Book] = None
        self._paragraph_split_chars = paragraph_split_chars
        if file_path is not None:
            self.file_path = Path(file_path)
            self.load(file_path, paragraph_split_chars=paragraph_split_chars)

    def load(
        self,
        file_path: str | Path,
        paragraph_split_chars: Optional[int] = None,
    ) -> None:
        path = Path(file_path)
        if not path.exists():
            raise FileNotFoundError(f"File not found: {path}")

        suffix = path.suffix.lower()
        _mobi_suffixes = {".mobi", ".azw", ".azw3", ".prc"}
        if suffix not in {".epub", ".pdf", ".fb2", ".cbz", ".cbr", ".docx"} | _mobi_suffixes:
            raise ValueError(f"Unsupported format: {suffix}")

        ps_chars = (
            paragraph_split_chars
            if paragraph_split_chars is not None
            else self._paragraph_split_chars
        )
        self._paragraph_split_chars = ps_chars
        self.file_path = path
        if suffix == ".epub":
            self.book = EpubParser(str(path), paragraph_split_chars=ps_chars).parse()
        elif suffix == ".fb2":
            # Local import: fb2_parser imports Book/Chapter/EpubParser/TocItem
            # from this module, so a module-level import here would be circular.
            from .fb2_parser import Fb2Parser

            self.book = Fb2Parser(str(path)).parse()
        elif suffix == ".cbz":
            from .cbz_parser import CbzParser

            self.book = CbzParser(str(path)).parse()
        elif suffix == ".cbr":
            from .cbr_parser import CbrParser

            self.book = CbrParser(str(path)).parse()
        elif suffix == ".docx":
            from .docx_parser import DocxParser

            self.book = DocxParser(str(path)).parse()
        elif suffix in _mobi_suffixes:
            from .mobi_drm import raise_if_drm_protected
            from .mobi_parser import MobiParser

            raise_if_drm_protected(path)
            self.book = MobiParser(str(path)).parse()
        else:
            self.book = PdfParser(str(path)).parse()

    @property
    def title(self) -> str:
        return self.book.title if self.book else ""

    @property
    def author(self) -> str:
        return self.book.author if self.book else ""

    @property
    def language(self) -> Optional[str]:
        """Get the language code from EPUB metadata (e.g., 'en', 'pt')."""
        return self.book.language if self.book else None

    def get_chapters(self) -> List[Chapter]:
        return list(self.book.chapters) if self.book else []

    def _ensure_loaded(self) -> Optional[Book]:
        if not self.book:
            if not self.file_path:
                raise RuntimeError("Reader has no file loaded")
            self.load(self.file_path)
        return self.book

    def get_chapter_structure(self, preserve_all: bool = True) -> List[Chapter]:
        chapters = self.get_chapters()
        if preserve_all:
            return chapters
        return [chapter for chapter in chapters if len(chapter.text.strip()) >= 100]

    def read_ebook(self, file_path: str | Path) -> Tuple[str, str, List[Tuple[str, str]]]:
        self.load(file_path)
        if not self.book:
            return "", "", []
        chapters = [(chapter.name, chapter.text) for chapter in self.book.chapters]
        return self.book.title, self.book.author, chapters

    def get_toc(self) -> List[TocItem]:
        book = self._ensure_loaded()
        if not book:
            return []
        return list(book.toc)


def read_book(file_path: str | Path) -> Book:
    reader = EbookReader(file_path)
    if not reader.book:
        raise RuntimeError("Failed to read book")
    return reader.book


__all__ = ["EbookReader", "read_book", "parse_epub_to_dict", "Book", "Chapter"]
