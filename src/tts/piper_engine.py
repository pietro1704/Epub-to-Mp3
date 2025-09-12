# -*- coding: utf-8 -*-
"""Ultra-simplified Piper TTS Engine"""

import asyncio
import tempfile
from pathlib import Path

class PiperTTSEngine:
    def __init__(self, model_path: Path = None):
        self.model_path = model_path or self._find_model()
        if not self.model_path or not self.model_path.exists():
            raise FileNotFoundError("Piper model not found in models/ directory")
    
    def _find_model(self) -> Path:
        """Find first available Piper model"""
        models_dir = Path("models")
        if models_dir.exists():
            for model in models_dir.glob("*.onnx"):
                return model
        return None
    
    async def synthesize_async(self, text: str, output_path: Path) -> Path:
        """Synthesize text to audio file"""
        if not text.strip():
            return output_path
            
        # Run piper command
        cmd = [
            "piper", 
            "--model", str(self.model_path),
            "--output_file", str(output_path)
        ]
        
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL
        )
        
        await process.communicate(input=text.encode('utf-8'))
        return output_path if output_path.exists() else None