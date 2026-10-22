import os
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import (
    ChapterStructureItem,
    ConverterApplication,
    _apply_overnight_preset,
    create_argument_parser,
    main,
)
from src.ebook_reader import Chapter


def _asyncio_run_stub(coro):
    try:
        coro.close()
    except RuntimeError:
        pass
    return 0


__all__ = [
    "Chapter",
    "ChapterStructureItem",
    "ConverterApplication",
    "Mock",
    "Namespace",
    "Path",
    "SimpleNamespace",
    "_apply_overnight_preset",
    "_asyncio_run_stub",
    "create_argument_parser",
    "main",
    "os",
    "patch",
    "subprocess",
    "sys",
    "tempfile",
    "unittest",
]
