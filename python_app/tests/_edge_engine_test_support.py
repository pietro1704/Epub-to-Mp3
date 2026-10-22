import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.tts import edge_engine
from src.tts.edge_engine import SIMPLIFIED_SEGMENT_MAX_CHARS, EdgeTTSEngine


__all__ = [
    "EdgeTTSEngine",
    "Mock",
    "Path",
    "SIMPLIFIED_SEGMENT_MAX_CHARS",
    "asyncio",
    "edge_engine",
    "os",
    "sys",
    "tempfile",
    "unittest",
]
