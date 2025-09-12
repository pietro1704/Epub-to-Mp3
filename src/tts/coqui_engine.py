# -*- coding: utf-8 -*-
"""Ultra-simplified Coqui TTS Engine"""

import asyncio
import tempfile
from pathlib import Path

class CoquiTTSEngine:
    def __init__(self, model_name: str = "tts_models/multilingual/multi-dataset/xtts_v2"):
        self.model_name = model_name
        try:
            from TTS.api import TTS
            self.tts = TTS(model_name)
        except ImportError:
            raise ImportError("Coqui TTS not installed: pip install TTS torch torchaudio")
    
    async def synthesize_async(self, text: str, output_path: Path) -> Path:
        """Synthesize text to audio file"""
        if not text.strip():
            return output_path
            
        # Run in thread pool since TTS is CPU intensive
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, self._synthesize_sync, text, output_path)
        return output_path if output_path.exists() else None
    
    def _synthesize_sync(self, text: str, output_path: Path):
        """Synchronous synthesis"""
        self.tts.tts_to_file(text=text, file_path=str(output_path))