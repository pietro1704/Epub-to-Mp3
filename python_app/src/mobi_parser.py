"""MOBI/AZW/AZW3 parser — server/CLI only, never embedded in the iOS/macOS
app (see docs/reader-spec-comparison.md P1: the `mobi` package and its
transitive deps aren't vendored into the on-device Python embed, and
`BookFileType.requiresServerConversion` gates the Swift side before it ever
reaches `PythonBridge`).

Uses the third-party `mobi` package (KindleUnpack under the hood) to unpack
the container. For KF8 (AZW3) sources it produces a real EPUB file, fed
straight into the existing `EpubParser` — full reuse, zero new HTML
-conversion glue. For legacy MOBI7-only sources (no KF8 data) it produces a
single `book.html` file instead, which goes through the shared
`_html_fragment_to_chapters` pipeline directly, same as FB2/DOCX.

DRM must be checked by the caller (`mobi_drm.raise_if_drm_protected`)
BEFORE this class is used — by the time `mobi.extract` runs on a protected
file it's already too late to give a clean error.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from .ebook_reader import Book, EpubParser


class MobiParseError(Exception):
    """Raised when a MOBI/AZW/AZW3 file cannot be unpacked or parsed."""


class MobiParser:
    def __init__(self, file_path: str | Path) -> None:
        self.file_path = Path(file_path)

    def parse(self) -> Book:
        try:
            import mobi
        except ImportError as exc:
            raise MobiParseError(
                "MOBI/AZW support requires the 'mobi' package, which is only "
                "installed on the server/CLI — not embedded on-device."
            ) from exc

        try:
            tempdir, extracted_path = mobi.extract(str(self.file_path))
        except Exception as exc:
            raise MobiParseError(f"Failed to unpack MOBI/AZW: {exc}") from exc

        try:
            extracted = Path(extracted_path)
            suffix = extracted.suffix.lower()
            if suffix == ".epub":
                return EpubParser(str(extracted)).parse()
            if suffix in (".html", ".htm"):
                html = extracted.read_text(encoding="utf-8", errors="ignore")
                chapters = EpubParser._html_fragment_to_chapters(
                    markup_with_markers=html,
                    raw_content=html,
                    chapter_idx=1,
                    asset_path="mobi-content",
                    toc_chapter_title=None,
                    footnotes=None,
                    cue_locale="en",
                )
                return Book(title=self.file_path.stem, author="", chapters=chapters)
            raise MobiParseError(f"Unexpected mobi.extract() output: {extracted_path}")
        finally:
            shutil.rmtree(tempdir, ignore_errors=True)


__all__ = ["MobiParser", "MobiParseError"]
