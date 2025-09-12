# -*- coding: utf-8 -*-
"""Ultra-simplified Edge-TTS Engine"""

import asyncio
from pathlib import Path

class EdgeTTSEngine:
    def __init__(self, voice: str = "pt-BR-FranciscaNeural"):
        self.voice = voice
        try:
            import edge_tts
            self._edge_tts = edge_tts
        except ImportError:
            raise ImportError("Edge-TTS not installed: pip install edge-tts")
    
    async def synthesize_async(self, text: str, output_path: Path) -> Path:
        """Synthesize text to audio file"""
        if not text.strip():
            return output_path
            
        communicate = self._edge_tts.Communicate(text, self.voice)
        await communicate.save(str(output_path))
        return output_path if output_path.exists() else None