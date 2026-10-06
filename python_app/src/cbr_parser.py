"""CBR (RAR comic book) parser for server/CLI visual reading."""

from __future__ import annotations

import mimetypes
import re
from pathlib import Path

from .ebook_reader import Book, Chapter

_IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}


class CbrParseError(Exception):
    """Raised when a CBR archive cannot be read."""


def _natural_sort_key(name: str) -> list:
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", name)]


class CbrParser:
    """Parse a CBR archive into one image-only chapter per page."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = Path(file_path)

    def parse(self) -> Book:
        try:
            import rarfile
        except ImportError as exc:
            raise CbrParseError(
                "CBR support requires the 'rarfile' package on the server."
            ) from exc

        try:
            with rarfile.RarFile(self.file_path, "r") as archive:
                names = [
                    name
                    for name in archive.namelist()
                    if not name.endswith("/") and Path(name).suffix.lower() in _IMAGE_SUFFIXES
                ]
        except Exception as exc:
            raise CbrParseError(f"Failed to read CBR archive: {exc}") from exc

        names.sort(key=_natural_sort_key)
        chapters = [
            Chapter(
                index=index,
                name=f"Page {index}",
                source_path=name,
                text="",
            )
            for index, name in enumerate(names, 1)
        ]
        return Book(title=self.file_path.stem, author="", chapters=chapters)


def read_page(file_path: str | Path, member: str) -> tuple[bytes, str, str]:
    """Read one CBR page and return bytes, media type, and extension."""
    try:
        import rarfile
    except ImportError as exc:
        raise CbrParseError("CBR support requires the 'rarfile' package on the server.") from exc

    try:
        with rarfile.RarFile(file_path, "r") as archive:
            data = archive.read(member)
    except Exception as exc:
        raise CbrParseError(f"Failed to read CBR page: {exc}") from exc

    extension = Path(member).suffix or ".jpg"
    media_type = mimetypes.guess_type(member)[0] or "image/jpeg"
    return data, media_type, extension


__all__ = ["CbrParser", "CbrParseError", "read_page"]
