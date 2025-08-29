# -*- coding: utf-8 -*-
"""
Interface base para engines TTS - seguindo princípios SOLID
"""

from abc import ABC, abstractmethod
from typing import Optional, Dict, Any
from pathlib import Path


class TTSEngine(ABC):
    """Interface base para todos os engines TTS (Interface Segregation Principle)"""
    
    def __init__(self, voice: str, **kwargs):
        self.voice = voice
        self.config = kwargs
        self._validate_dependencies()
    
    @abstractmethod
    def _validate_dependencies(self) -> None:
        """Valida se as dependências do engine estão disponíveis"""
        pass
    
    @abstractmethod
    async def synthesize(self, text: str, output_path: Path) -> bool:
        """
        Sintetiza texto para áudio
        
        Args:
            text: Texto para sintetizar
            output_path: Caminho para salvar o arquivo de áudio
            
        Returns:
            bool: True se sucesso, False caso contrário
        """
        pass
    
    @abstractmethod
    def get_max_chunk_size(self) -> int:
        """Retorna o tamanho máximo de texto por chunk"""
        pass
    
    @abstractmethod
    def get_voice_info(self) -> Dict[str, Any]:
        """Retorna informações sobre a voz selecionada"""
        pass
    
    def supports_ssml(self) -> bool:
        """Indica se o engine suporta SSML"""
        return False
    
    def get_supported_formats(self) -> list:
        """Retorna formatos de áudio suportados"""
        return ['mp3', 'wav']
    
    def cleanup(self) -> None:
        """Limpeza de recursos (Template Method Pattern)"""
        pass