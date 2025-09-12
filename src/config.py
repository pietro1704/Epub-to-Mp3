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
    preserve_all_chapters: bool = True
    
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
    
    def create_conversion_config(self, engine: str, voice: Optional[str] = None,
                               model: Optional[str] = None, **kwargs) -> ConversionConfig:
        """Create conversion configuration"""
        config = ConversionConfig(engine=engine, **kwargs)
        
        if voice:
            config.voice = voice
        if model:
            config.model_path = Path(model)
            
        return config


class VoiceConfigProvider:
    """Provides voice configuration data - following SRP"""
    
    @property
    def edge_voices(self) -> Dict[str, tuple]:
        """Edge-TTS voices"""
        return {
            "1": ("pt-BR-FranciscaNeural", "Francisca - Feminina, recomendada ⭐"),
            "2": ("pt-BR-AntonioNeural", "Antonio - Masculino, padrão"),
            "3": ("pt-BR-BrendaNeural", "Brenda - Feminina, jovem"),
        }
    
    @property
    def coqui_models(self) -> Dict[str, tuple]:
        """Coqui TTS models"""
        return {
            "1": ("tts_models/multilingual/multi-dataset/xtts_v2", 
                  "XTTS v2 Multilíngue", "Melhor qualidade ⭐", True),
            "2": ("tts_models/pt/cv/vits", 
                  "Português CV-VITS", "Rápido", False),
        }
    
    def get_piper_models(self) -> Dict[str, Dict[str, Any]]:
        """Get available Piper models from models directory"""
        models_dir = Path("models")
        if not models_dir.exists():
            return {}
        
        models = {}
        for model_file in models_dir.glob("*.onnx"):
            models[model_file.stem] = {
                "name": model_file.stem,
                "path": model_file,
                "size_mb": model_file.stat().st_size // (1024 * 1024),
                "recommended": "faber" in model_file.name.lower()
            }
        
        return models


# Constants for backward compatibility
DEFAULT_CONFIG = ConversionConfig(engine="edge")
SUPPORTED_FORMATS = [".epub", ".pdf"]
AUDIO_FORMATS = ["mp3"]