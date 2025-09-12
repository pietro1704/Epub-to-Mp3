# -*- coding: utf-8 -*-
"""
Simplified TTS Factory - SOLID principles applied
Reduced complexity while maintaining extensibility
"""

from typing import Protocol
from pathlib import Path
from ..config import ConversionConfig


class TTSEngine(Protocol):
    """TTS Engine interface following Interface Segregation Principle"""
    
    async def synthesize_async(self, text: str, output_path: Path) -> Path:
        """Synthesize text to audio file asynchronously"""
        ...


class TTSFactory:
    """Factory for creating TTS engines following Open/Closed Principle"""
    
    def create_engine(self, config: ConversionConfig) -> TTSEngine:
        """Create TTS engine based on configuration"""
        if config.engine == "edge":
            from .edge_engine import EdgeTTSEngine
            return EdgeTTSEngine(config.voice or "pt-BR-FranciscaNeural")
        
        elif config.engine == "coqui":
            from .coqui_engine import CoquiTTSEngine
            return CoquiTTSEngine(config.voice or "tts_models/multilingual/multi-dataset/xtts_v2")
        
        elif config.engine == "piper":
            from .piper_engine import PiperTTSEngine
            return PiperTTSEngine(config.model_path or self._find_piper_model())
        
        else:
            raise ValueError(f"Unsupported engine: {config.engine}")
    
    def _find_piper_model(self) -> Path:
        """Find first available Piper model"""
        models_dir = Path("models")
        if models_dir.exists():
            for model_file in models_dir.glob("*.onnx"):
                return model_file
        
        raise FileNotFoundError("No Piper models found in models/ directory")