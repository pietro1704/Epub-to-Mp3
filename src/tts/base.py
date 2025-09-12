# -*- coding: utf-8 -*-
"""Ultra-simplified TTS Base - Just protocol definition"""

from typing import Protocol
from pathlib import Path

class TTSEngine(Protocol):
    """TTS Engine interface"""
    async def synthesize_async(self, text: str, output_path: Path) -> Path:
        """Synthesize text to audio file"""
        ...