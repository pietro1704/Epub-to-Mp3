# -*- coding: utf-8 -*-
"""
Factory para criação de engines TTS - seguindo padrão Factory e princípios SOLID
"""

from typing import Dict, Type, Any
from .base import TTSEngine
from .edge_engine import EdgeTTSEngine
from .coqui_engine import CoquiTTSEngine
from .piper_engine import PiperTTSEngine


class TTSEngineRegistry:
    """Registry para engines TTS (Open/Closed Principle)"""
    
    def __init__(self):
        self._engines: Dict[str, Type[TTSEngine]] = {}
        self._register_default_engines()
    
    def _register_default_engines(self):
        """Registra engines padrão"""
        self.register('edge', EdgeTTSEngine)
        self.register('coqui', CoquiTTSEngine) 
        self.register('piper', PiperTTSEngine)
    
    def register(self, name: str, engine_class: Type[TTSEngine]):
        """Registra novo engine (permite extensão sem modificação)"""
        if not issubclass(engine_class, TTSEngine):
            raise ValueError(f"Engine {engine_class} deve herdar de TTSEngine")
        
        self._engines[name] = engine_class
    
    def get_engine_class(self, name: str) -> Type[TTSEngine]:
        """Retorna classe do engine"""
        if name not in self._engines:
            raise ValueError(f"Engine '{name}' não registrado. Disponíveis: {list(self._engines.keys())}")
        
        return self._engines[name]
    
    def list_engines(self) -> Dict[str, Type[TTSEngine]]:
        """Lista todos os engines registrados"""
        return self._engines.copy()


class TTSFactory:
    """Factory principal para criação de engines TTS"""
    
    def __init__(self, registry: TTSEngineRegistry = None):
        self.registry = registry or TTSEngineRegistry()
    
    def create_engine(self, engine_name: str, voice: str, **config) -> TTSEngine:
        """
        Cria instância de engine TTS
        
        Args:
            engine_name: Nome do engine ('edge', 'coqui', 'piper')
            voice: Voz/modelo a ser usado
            **config: Configurações específicas do engine
            
        Returns:
            TTSEngine: Instância do engine configurado
            
        Raises:
            ValueError: Se engine não existir
            ImportError: Se dependências não estiverem instaladas
        """
        try:
            engine_class = self.registry.get_engine_class(engine_name)
            return engine_class(voice=voice, **config)
            
        except Exception as e:
            raise RuntimeError(f"Erro ao criar engine '{engine_name}': {e}")
    
    def validate_engine_available(self, engine_name: str) -> bool:
        """Valida se engine está disponível (dependências instaladas)"""
        try:
            engine_class = self.registry.get_engine_class(engine_name)
            # Tenta criar instância temporária para validar dependências
            temp_engine = engine_class(voice="temp")
            return True
            
        except Exception:
            return False
    
    def get_available_engines(self) -> Dict[str, bool]:
        """Retorna dict de engines e sua disponibilidade"""
        availability = {}
        for name in self.registry.list_engines().keys():
            availability[name] = self.validate_engine_available(name)
        
        return availability
    
    def register_custom_engine(self, name: str, engine_class: Type[TTSEngine]):
        """Permite registro de engines customizados"""
        self.registry.register(name, engine_class)


# Instância global do factory (Singleton Pattern)
_global_factory = None

def get_tts_factory() -> TTSFactory:
    """Retorna instância global do factory"""
    global _global_factory
    if _global_factory is None:
        _global_factory = TTSFactory()
    return _global_factory


def create_tts_engine(engine_name: str, voice: str, **config) -> TTSEngine:
    """Função de conveniência para criar engines"""
    factory = get_tts_factory()
    return factory.create_engine(engine_name, voice, **config)