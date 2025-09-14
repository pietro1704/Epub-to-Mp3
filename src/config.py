# -*- coding: utf-8 -*-
"""
Simplified configuration - SOLID principles applied
Reduced from 260 to ~80 lines by removing hardcoded data and applying SRP
"""

from dataclasses import dataclass
from typing import Dict, Any, Optional
from pathlib import Path


@dataclass
class ConversionConfig:
    """Configuration for audio conversion"""
    engine: str
    voice: Optional[str] = None
    model_path: Optional[Path] = None
    output_dir: str = "output"
    book_title: str = ""
    
    # Audio settings
    bitrate: str = "32k"
    sample_rate: int = 22050
    channels: int = 1
    
    # Processing settings
    max_parallel: int = 3
    force_reprocess: bool = False


class AppConfig:
    """Application configuration manager following SRP"""

    def __init__(self):
        self.voice_configs = VoiceConfigProvider()

    def create_conversion_config(self, engine: str, **kwargs) -> ConversionConfig:
        """Create conversion configuration"""
        return ConversionConfig(engine=engine, **kwargs)


class VoiceConfigProvider:
    """Provides voice configurations"""

    def get_voice(self, engine: str) -> Optional[str]:
        """Retrieve default voice for the engine"""
        voices = {
            "edge": "en-US-GuyNeural",
            "coqui": "tts_models/en/ljspeech/tacotron2-DDC_ph",
        }
        return voices.get(engine)


# Constants for backward compatibility
DEFAULT_CONFIG = ConversionConfig(engine="edge", voice="pt-BR-AntonioNeural")
SUPPORTED_FORMATS = [".epub", ".pdf"]
AUDIO_FORMATS = ["mp3"]