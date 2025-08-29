# -*- coding: utf-8 -*-
"""
Coqui TTS Engine - AI-powered local TTS
"""

import os
from pathlib import Path
from typing import Dict, Any, Optional
from .base import TTSEngine


class CoquiTTSEngine(TTSEngine):
    """Engine Coqui TTS local com IA"""
    
    def _validate_dependencies(self) -> None:
        """Valida dependências do Coqui TTS"""
        try:
            from TTS.api import TTS
            self._tts_class = TTS
        except ImportError:
            raise ImportError(
                "Coqui TTS não instalado. Execute: pip install TTS torch torchaudio"
            )
    
    async def synthesize(self, text: str, output_path: Path) -> bool:
        """Sintetiza texto usando Coqui TTS"""
        try:
            # Coqui TTS não é async nativo, mas rodamos em thread
            import asyncio
            return await asyncio.get_event_loop().run_in_executor(
                None, self._synthesize_sync, text, output_path
            )
            
        except Exception as e:
            print(f"❌ Erro Coqui TTS: {e}")
            return False
    
    def _synthesize_sync(self, text: str, output_path: Path) -> bool:
        """Síntese síncrona do Coqui TTS"""
        try:
            # Limita texto para Coqui TTS
            if len(text) > self.get_max_chunk_size():
                text = text[:self.get_max_chunk_size()]
            
            # Inicializa TTS model
            tts = self._tts_class(model_name=self.voice)
            
            # Verifica se tem voice cloning configurado
            reference_voice = self.config.get('reference_voice')
            if reference_voice and Path(reference_voice).exists():
                # Voice cloning mode
                tts.tts_to_file(
                    text=text,
                    speaker_wav=reference_voice,
                    file_path=str(output_path)
                )
            else:
                # Standard synthesis
                tts.tts_to_file(
                    text=text,
                    file_path=str(output_path)
                )
            
            # Valida arquivo gerado
            return output_path.exists() and output_path.stat().st_size > 1000
            
        except Exception as e:
            print(f"❌ Erro síntese Coqui: {e}")
            return False
    
    def get_max_chunk_size(self) -> int:
        """Coqui TTS é mais limitado para chunks"""
        return 1500
    
    def get_voice_info(self) -> Dict[str, Any]:
        """Informações da voz Coqui TTS"""
        return {
            'engine': 'coqui-tts',
            'model': self.voice,
            'language': 'multilingual',
            'quality': 'high',
            'online_required': False,
            'supports_cloning': True,
            'reference_voice': self.config.get('reference_voice'),
            'description': f'Modelo neural Coqui: {self.voice}'
        }
    
    def supports_voice_cloning(self) -> bool:
        """Coqui TTS suporta clonagem de voz"""
        return True
    
    def set_reference_voice(self, reference_path: str) -> None:
        """Define voz de referência para clonagem"""
        if Path(reference_path).exists():
            self.config['reference_voice'] = reference_path
        else:
            raise FileNotFoundError(f"Arquivo de referência não encontrado: {reference_path}")
    
    def cleanup(self) -> None:
        """Limpa cache de modelos"""
        try:
            import torch
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except ImportError:
            pass