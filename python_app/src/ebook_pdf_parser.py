# -*- coding: utf-8 -*-
"""PDF text extraction and scanned-page OCR caching."""

from __future__ import annotations

from pathlib import Path
from typing import List

from .ebook_models import Book, Chapter
from .pdf_scan_ocr import PdfOcrPage


class PdfParser:
    """Parse a PDF into chapters with optional scanned-page OCR."""

    def __init__(self, file_path: str | Path) -> None:
        from . import ebook_reader as _runtime
        self.file_path = str(file_path)
        self.path = _runtime.Path(file_path)

    def parse(self) -> Book:
        from . import ebook_reader as _runtime
        if not _runtime.PDF_AVAILABLE:
            raise ImportError("pypdf library not installed")

        with open(self.file_path, "rb") as handle:  # pragma: no cover - exercised in tests
            reader = _runtime.pypdf.PdfReader(handle)  # type: ignore[arg-type]

            metadata = reader.metadata or {}
            title = metadata.get("/Title") or metadata.get("Title") or self.path.stem
            author = metadata.get("/Author") or metadata.get("Author") or ""

            extracted_pages: dict[int, str] = {}
            extraction_error_pages: set[int] = set()
            for idx, page in enumerate(reader.pages, start=1):
                try:
                    raw_text = page.extract_text() or ""
                except Exception:
                    extraction_error_pages.add(idx)
                    continue

                # First join broken lines, then normalize whitespace
                joined_text = _runtime.TextProcessor.join_broken_lines(raw_text)
                cleaned = _runtime.TextProcessor.normalise_whitespace(joined_text)
                if not cleaned:
                    continue
                cleaned = _runtime.TextProcessor.add_pause_before_dash(cleaned)
                extracted_pages[idx] = cleaned

            page_count = len(reader.pages)

        pages_needing_recovery = [
            index for index in range(1, page_count + 1) if index not in extracted_pages
        ]
        scanned_pages: dict[int, list[PdfOcrPage]] = {}
        should_ocr = bool(pages_needing_recovery) and (
            not extracted_pages or len(pages_needing_recovery) * 4 >= page_count * 3
        )
        if should_ocr:
            cached_book = self._load_scanned_pdf_cache()
            if cached_book is not None:
                return cached_book
            for recovered in _runtime.PdfScanOcr().extract(self.path, pages_needing_recovery):
                scanned_pages.setdefault(recovered.source_page_index, []).append(recovered)

        chapters: List[_runtime.Chapter] = []
        for idx in range(1, page_count + 1):
            native_text = extracted_pages.get(idx)
            if native_text:
                chapters.append(self._make_chapter(idx, native_text))
                continue
            recovered_pages = sorted(scanned_pages.get(idx, []), key=lambda page: page.part_index)
            for recovered in recovered_pages:
                chapters.append(
                    self._make_chapter(
                        f"{idx}.{recovered.part_index}",
                        recovered.text,
                        source_path=f"page_{idx}_part_{recovered.part_index}",
                    )
                )
            if idx in extraction_error_pages and not recovered_pages:
                chapters.append(
                    _runtime.Chapter(
                        index=idx,
                        name=f"Página {idx} (erro)",
                        source_path=f"page_{idx}",
                        text="",
                    )
                )

        if page_count and not chapters:
            raise RuntimeError("No readable text could be extracted from the PDF")
        book = _runtime.Book(
            title=str(title),
            author=str(author),
            chapters=chapters,
            source_format="pdf_scan_ocr" if scanned_pages else None,
        )
        if scanned_pages:
            self._save_scanned_pdf_cache(book)
        return book

    def _load_scanned_pdf_cache(self) -> Book | None:
        """Return valid OCR output without rasterizing the same PDF twice."""
        from . import ebook_reader as _runtime
        cached = _runtime.CacheManager().get_cached_chapters(self.path)
        if not cached or cached.get("source_format") != "pdf_scan_ocr":
            return None
        cached_chapters = cached.get("chapters")
        if not isinstance(cached_chapters, list) or not cached_chapters:
            return None

        chapters: list[_runtime.Chapter] = []
        for position, payload in enumerate(cached_chapters, start=1):
            if not isinstance(payload, dict):
                return None
            text = str(payload.get("text") or "").strip()
            if not text:
                return None
            has_raw_identity = "source_path" in payload
            index = payload.get("index", position) if has_raw_identity else position
            name = (
                str(payload.get("title") or f"Página {index}")
                if has_raw_identity
                else f"Página {index}"
            )
            source_path = str(payload.get("source_path") or f"cached_page_{index}")
            speech_text = str(payload.get("speech_text") or text)
            chapters.append(
                _runtime.Chapter(
                    index=index,
                    name=name,
                    source_path=source_path,
                    text=text,
                    speech_text=speech_text,
                )
            )
        return _runtime.Book(
            title=str(cached.get("title") or self.path.stem),
            author=str(cached.get("author") or ""),
            chapters=chapters,
            source_format="pdf_scan_ocr",
        )

    def _save_scanned_pdf_cache(self, book: Book) -> None:
        """Persist raw OCR chapters once the complete scan was recovered."""
        from . import ebook_reader as _runtime
        _runtime.CacheManager().save_chapters_to_cache(
            self.path,
            {
                "title": book.title,
                "author": book.author,
                "source_format": "pdf_scan_ocr",
                "chapters": [
                    {
                        "index": chapter.index,
                        "title": chapter.name,
                        "source_path": chapter.source_path,
                        "text": chapter.text,
                        "speech_text": chapter.speech_text,
                    }
                    for chapter in book.chapters
                ],
            },
        )

    @staticmethod
    def _make_chapter(index: int | str, text: str, source_path: str | None = None) -> Chapter:
        from . import ebook_reader as _runtime
        page_title = f"Página {index}"
        return _runtime.Chapter(
            index=index,
            name=page_title,
            source_path=source_path or f"page_{index}",
            text=text,
            speech_text=_runtime.TextProcessor.apply_structural_speech_cues(
                text,
                chapter_title=page_title,
            ),
        )
