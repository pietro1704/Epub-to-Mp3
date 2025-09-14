# -*- coding: utf-8 -*-
"""
Simplified menu interface - SOLID principles applied
Reduced from 218 to ~100 lines by focusing on core functionality
"""

from typing import Optional
from ..config import ConversionConfig, VoiceConfigProvider
from ..ebook_reader import EbookReader


class MenuInterface:
    """Simple menu interface following SRP"""
    
    def __init__(self):
        self.voice_provider = VoiceConfigProvider()
    
    def get_conversion_config(self, reader: EbookReader) -> Optional[ConversionConfig]:
        """Get conversion configuration through interactive menu"""
        print(f"\n📚 Book: {reader.title}")
        print(f"👤 Author: {reader.author}")
        print(f"📄 Chapters: {len(reader.get_chapters())}")
        
        # Choose engine
        engine = self._choose_engine()
        if not engine:
            return None
        
        # Choose voice/model based on engine
        voice = self._choose_voice(engine)
        
        # Basic configuration
        return ConversionConfig(
            engine=engine,
            voice=voice,
            book_title=reader.title
        )
    
    def _choose_engine(self) -> Optional[str]:
        """Choose TTS engine"""
        print("\n🎵 Choose TTS Engine:")
        print("1. Edge-TTS (Microsoft, online, fast)")
        print("2. Coqui TTS (Local AI, high quality)")
        print("3. Piper TTS (Local, lightweight)")
        print("0. Exit")
        
        choice = input("Select engine (1-3): ").strip()
        
        engines = {"1": "edge", "2": "coqui", "3": "piper", "0": None}
        return engines.get(choice)
    
    def _choose_voice(self, engine: str) -> Optional[str]:
        """Choose voice based on engine"""
        if engine == "edge":
            return self._choose_edge_voice()
        elif engine == "coqui":
            return self._choose_coqui_model()
        elif engine == "piper":
            return self._choose_piper_model()
        return None
    
    def _choose_edge_voice(self) -> Optional[str]:
        """Choose Edge-TTS voice"""
        print("\n🗣️ Choose Voice:")
        
        voices = self.voice_provider.edge_voices
        for key, (voice_id, description) in voices.items():
            print(f"{key}. {description}")
        
        choice = input("Select voice (1-3): ").strip()
        if choice in voices:
            return voices[choice][0]
        
        # Default
        return "pt-BR-AntonioNeural"
    
    def _choose_coqui_model(self) -> Optional[str]:
        """Choose Coqui model"""
        print("\n🤖 Choose Model:")
        
        models = self.voice_provider.coqui_models
        for key, (model_id, name, desc, _) in models.items():
            print(f"{key}. {name} - {desc}")
        
        choice = input("Select model (1-2): ").strip()
        if choice in models:
            return models[choice][0]
        
        # Default
        return "tts_models/multilingual/multi-dataset/xtts_v2"
    
    def _choose_piper_model(self) -> Optional[str]:
        """Choose Piper model"""
        print("\n🎭 Piper models:")
        print("Please place .onnx model files in the 'models' directory")
        print("Default: will look for any .onnx file in models/")
        
        # Simple default - user can place model files in models directory
        return None  # Will be auto-detected by engine