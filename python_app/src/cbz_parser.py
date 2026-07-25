"""CBZ (comic book zip archive) parser.

CBZ files have no text — they're an ordered sequence of page images. There is
no manifest/spine, so page order comes from a natural sort of the zip member
names. Each page becomes one `Chapter` with `text=""`; `source_path` holds
the archive member name so `EbookReader.extract_chapter_resources` can read
the page bytes back for the reader UI. There is deliberately no TTS-relevant
content here (see `docs/reader-spec-comparison.md` P1: comics are read
visually, not converted to audio).
"""

from __future__ import annotations

import re
import zipfile
from pathlib import Path
from typing import List

from .ebook_reader import Book, Chapter

_IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}


class CbzParseError(Exception):
    """Raised when a file cannot be opened as a valid CBZ (zip) archive."""


def _natural_sort_key(name: str) -> list:
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", name)]


class CbzParser:
    """Parses a CBZ comic archive into the shared `Book`/`Chapter` model."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = Path(file_path)

    def parse(self) -> Book:
        try:
            with zipfile.ZipFile(self.file_path, "r") as archive:
                names = [
                    n
                    for n in archive.namelist()
                    if not n.endswith("/") and Path(n).suffix.lower() in _IMAGE_SUFFIXES
                ]
        except zipfile.BadZipFile as exc:
            raise CbzParseError(f"Invalid CBZ (not a zip archive): {exc}") from exc

        names.sort(key=_natural_sort_key)
        chapters: List[Chapter] = [
            Chapter(index=idx, name=f"Página {idx}", source_path=name, text="")
            for idx, name in enumerate(names, 1)
        ]
        return Book(title=self.file_path.stem, author="", chapters=chapters)


__all__ = ["CbzParser", "CbzParseError"]
