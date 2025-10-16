# -*- coding: utf-8 -*-
"""Ultra-simplified TTS Base - Just protocol definition"""

from typing import Protocol
from pathlib import Path

class TTSEngine(Protocol):
    """TTS Engine interface"""

    def supports_multilingual(self) -> bool:
        """Return True if engine can handle [[lang:xx]] tags for language switching"""
        ...

    def supports_emphasis(self) -> bool:
        """Return True if engine can handle formatting/emphasis markers"""
        ...

    async def synthesize_async(self, text: str, output_path: Path, formatting_segments=None) -> Path:
        """Synthesize text to audio file"""
        ...