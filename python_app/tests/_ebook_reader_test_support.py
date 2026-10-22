import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import Mock, patch

from src.ebook_reader import (
    Book,
    Chapter,
    EbookReader,
    EpubParser,
    PdfParser,
    TocItem,
    parse_epub_to_dict,
)

__all__ = [
    "Book",
    "Chapter",
    "EbookReader",
    "EpubParser",
    "Mock",
    "Path",
    "PdfParser",
    "TocItem",
    "os",
    "parse_epub_to_dict",
    "patch",
    "tempfile",
    "unittest",
    "zipfile",
]
