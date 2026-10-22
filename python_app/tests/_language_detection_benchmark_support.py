import asyncio
import importlib.util
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

# Add parent to path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from langdetect import LangDetectException, detect

# Test sentences in multiple languages
TEST_SENTENCES = {
    "pt": [
        "Olá, este é um teste em português brasileiro.",
        "A inteligência artificial está revolucionando o mundo.",
        "O Brasil é o maior país da América do Sul.",
    ],
    "en": [
        "Hello, this is a test in English.",
        "Artificial intelligence is changing the world rapidly.",
        "The quick brown fox jumps over the lazy dog.",
    ],
    "es": [
        "Hola, esta es una prueba en español.",
        "La tecnología avanza cada día más rápido.",
        "Madrid es la capital de España.",
    ],
    "ja": [
        "こんにちは、これは日本語のテストです。",
        "人工知能は世界を変えています。",
        "東京は日本の首都です。",
    ],
    "zh": [
        "你好，这是中文测试。",
        "人工智能正在改变世界。",
        "北京是中国的首都。",
    ],
}

# Engine capabilities per language
ENGINE_LANGUAGE_SUPPORT = {
    "piper": {"pt", "en"},  # Has good models for PT and EN
    "kokoro": {"en", "ja", "zh"},  # Supports EN, JA, ZH (82M model)
    "edge": {"pt", "en", "es", "ja", "zh", "fr", "de", "it"},  # Cloud, all languages
}

# Best voice for each language per engine
LANGUAGE_VOICES = {
    "piper": {
        "pt": "pt_BR-faber-medium",
        "en": "en_US-lessac-medium",
    },
    "kokoro": {
        "en": "af_heart",  # American English
        "ja": "jf_alpha",  # Japanese
        "zh": "zf_xiaobei",  # Chinese
    },
    "edge": {
        "pt": "pt-BR-ThalitaMultilingualNeural",
        "en": "en-US-JennyNeural",
        "es": "es-ES-ElviraNeural",
        "ja": "ja-JP-NanamiNeural",
        "zh": "zh-CN-XiaoxiaoNeural",
    },
}


@dataclass
class BenchmarkResult:
    engine: str
    language: str
    approach: str  # "multilingual" or "detection"
    sentences: int
    total_chars: int
    total_time: float
    chars_per_second: float
    success_rate: float
    errors: List[str]




__all__ = [
    "BenchmarkResult",
    "Dict",
    "ENGINE_LANGUAGE_SUPPORT",
    "LANGUAGE_VOICES",
    "LangDetectException",
    "List",
    "Path",
    "TEST_SENTENCES",
    "Tuple",
    "asyncio",
    "dataclass",
    "detect",
    "importlib",
    "sys",
    "tempfile",
    "time",
]
