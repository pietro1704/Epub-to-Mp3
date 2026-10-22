"""Legacy CLI dependency identities, structure model and optional warm-up helpers."""

import argparse
import asyncio
import contextlib
import copy
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
import unicodedata
import zipfile
from dataclasses import dataclass
from dataclasses import replace as _dc_replace
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple
from urllib.parse import unquote

# macOS Intel + NumPy + Accelerate triggers FPE at import time. Disable Accelerate usage.
os.environ.setdefault("NPY_DISABLE_MAC_OS_ACCELERATE", "1")

try:  # Optional dependency for shell tab completion
    import argcomplete  # type: ignore
    from argcomplete.completers import ChoicesCompleter, FilesCompleter
except ImportError:  # pragma: no cover - argcomplete is optional
    argcomplete = None
    ChoicesCompleter = None
    FilesCompleter = None

# Local imports
from src.benchmark_profile import apply_benchmark_profile
from src.chapter_utils import deduplicate_chapters_by_content
from src.config import AppConfig, ConversionConfig
from src.converter import AudioConverter, ConversionResult
from src.ebook_reader import Chapter, EbookReader, FormattingSegment, TextProcessor
from src.i18n import get_localization
from src.language import (
    LanguageDetector,
    LanguageMarkup,
    LanguageProfile,
    get_language_detector,
)
from src.paths import JOB_INPUTS_DIR, JOBS_DIR, OUTPUT_DIR, UPLOADS_DIR
from src.text_formatting import PRESERVE_TTS_LAYOUT, TextFormattingProcessor
from src.ui.menu import MenuInterface
from src.utils import FileManager, resolve_cache_root

_FALLBACK_ENGINE_CHOICES = {"piper", "none"}








@dataclass
class ChapterStructureItem:
    chapter: Chapter
    index: str
    main_title: Optional[str]
    sub_title: Optional[str]
    preview: Optional[str]
    display_name: str
    text_override: Optional[str] = None
    speak_heading: bool = True



__all__ = [
    "Any",
    "AppConfig",
    "AudioConverter",
    "Chapter",
    "ChapterStructureItem",
    "ChoicesCompleter",
    "ConversionConfig",
    "ConversionResult",
    "Dict",
    "EbookReader",
    "FileManager",
    "FilesCompleter",
    "FormattingSegment",
    "JOBS_DIR",
    "JOB_INPUTS_DIR",
    "LanguageDetector",
    "LanguageMarkup",
    "LanguageProfile",
    "List",
    "MenuInterface",
    "OUTPUT_DIR",
    "Optional",
    "PRESERVE_TTS_LAYOUT",
    "Path",
    "Set",
    "TextFormattingProcessor",
    "TextProcessor",
    "Tuple",
    "UPLOADS_DIR",
    "_FALLBACK_ENGINE_CHOICES",
    "_dc_replace",
    "apply_benchmark_profile",
    "argcomplete",
    "argparse",
    "asyncio",
    "contextlib",
    "copy",
    "dataclass",
    "deduplicate_chapters_by_content",
    "get_language_detector",
    "get_localization",
    "glob",
    "hashlib",
    "json",
    "os",
    "re",
    "resolve_cache_root",
    "shutil",
    "subprocess",
    "sys",
    "time",
    "traceback",
    "unicodedata",
    "unquote",
    "zipfile",
]
