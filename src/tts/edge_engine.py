# -*- coding: utf-8 -*-
"""
Edge-TTS Engine - Microsoft Text-to-Speech
"""

import asyncio
from pathlib import Path
from typing import Dict, Any
from .base import TTSEngine


class EdgeTTSEngine(TTSEngine):
    """Engine Edge-TTS da Microsoft"""
    
    def _validate_dependencies(self) -> None:
        """Valida dependências do Edge-TTS"""
        try:
            import edge_tts
            self._edge_tts = edge_tts
        except ImportError:
            raise ImportError(
                "Edge-TTS não instalado. Execute: pip install edge-tts"
            )
    
    async def synthesize(self, text: str, output_path: Path) -> bool:
        """Sintetiza texto usando Edge-TTS"""
        try:
            # Limita texto para Edge-TTS (máximo recomendado)
            if len(text) > self.get_max_chunk_size():
                text = text[:self.get_max_chunk_size()]
            
            communicate = self._edge_tts.Communicate(text, self.voice)
            await communicate.save(str(output_path))
            
            # Valida se arquivo foi criado corretamente
            return output_path.exists() and output_path.stat().st_size > 1000
            
        except Exception as e:
            print(f"❌ Erro Edge-TTS: {e}")
            return False
    
    def get_max_chunk_size(self) -> int:
        """Edge-TTS suporta textos grandes"""
        return 8000
    
    def get_voice_info(self) -> Dict[str, Any]:
        """Informações da voz Edge-TTS"""
        return {
            'engine': 'edge-tts',
            'voice': self.voice,
            'language': 'pt-BR' if 'BR' in self.voice else 'pt-PT',
            'quality': 'high',
            'online_required': True,
            'gender': self._detect_gender(),
            'description': f'Voz neural Microsoft: {self.voice}'
        }
    
    def supports_ssml(self) -> bool:
        """Edge-TTS suporta SSML"""
        return True
    
    def _detect_gender(self) -> str:
        """Detecta gênero pela voz"""
        male_names = ['antonio', 'francisco', 'daniel']
        female_names = ['francisca', 'maria', 'ines', 'fernanda']
        
        voice_lower = self.voice.lower()
        
        if any(name in voice_lower for name in male_names):
            return 'male'
        elif any(name in voice_lower for name in female_names):
            return 'female'
        return 'unknown'