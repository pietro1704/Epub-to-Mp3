from __future__ import annotations

import io
import os
import shutil
import tempfile
import unittest
import unittest.mock
from pathlib import Path

from main import ConverterApplication
from src.ebook_reader import EbookReader, EpubParser, TextProcessor
from src.text_formatting import TextFormattingProcessor

FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures" / "epubs"
SAMPLE_EPUB = FIXTURE_ROOT / "test_multifeature.epub"
SAMPLE_MULTILANG = FIXTURE_ROOT / "sample_multilang.epub"


__all__ = [
    "ConverterApplication",
    "EbookReader",
    "EpubParser",
    "FIXTURE_ROOT",
    "Path",
    "SAMPLE_EPUB",
    "SAMPLE_MULTILANG",
    "TextFormattingProcessor",
    "TextProcessor",
    "io",
    "os",
    "shutil",
    "tempfile",
    "unittest",
]
