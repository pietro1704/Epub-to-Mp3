import asyncio
import json
import os
import re
import sys
import tempfile
import time
import unittest
import warnings
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.audio_validator import AudioValidator
from src.cache_manager import CacheManager
from src.config import ConversionConfig
from src.converter import (
    EDGE_OFFLINE_LONG_CHARS,
    AudioConverter,
    ChapterProcessor,
    ConversionResult,
    validate_audio_completeness,
)
from src.ebook_reader import Chapter
from src.engine_pool import ResourceSnapshot
from src.text_formatting import TextFormattingProcessor
from src.utils import TextValidator


class MockTTSEngine:
    """Base mock TTS engine with all required attributes for testing"""

    def __init__(self):
        self.last_error = None
        self.last_segment_report = None
        self.partial_failure_detected = False

    def get_synthesis_tracker(self):
        """Mock synthesis tracker that returns no missing segments"""
        return None

    async def synthesize_async(self, text, output_path, formatting_segments=None):
        """Default implementation - subclasses should override"""
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(b"fake audio" * 200)  # > 1000 bytes
        return output_path


__all__ = [
    "AsyncMock",
    "AudioConverter",
    "AudioValidator",
    "CacheManager",
    "Chapter",
    "ChapterProcessor",
    "ConversionConfig",
    "ConversionResult",
    "EDGE_OFFLINE_LONG_CHARS",
    "Mock",
    "MockTTSEngine",
    "Path",
    "ResourceSnapshot",
    "SimpleNamespace",
    "TextFormattingProcessor",
    "TextValidator",
    "asyncio",
    "datetime",
    "json",
    "os",
    "patch",
    "re",
    "replace",
    "sys",
    "tempfile",
    "time",
    "timezone",
    "unittest",
    "validate_audio_completeness",
    "warnings",
]
