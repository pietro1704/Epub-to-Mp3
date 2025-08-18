"""
src/tts_factory.py

Factory para criação de engines TTS.
"""

from typing import Dict, Any
from tts.edge_engine import EdgeTTSEngine
from tts.coqui_engine import CoquiTTSEngine
from tts.piper_engine import PiperTTSEngine


class TTSFactory:
    """Factory para criação de engines TTS apropriados."""
    
    def __init__(self):
        """Inicializa a factory."""
        self._engines = {
            'edge': EdgeTTSEngine,
            'coqui': CoquiTTSEngine,
            'piper': PiperTTSEngine
        }
    
    def create_engine(self, engine_type: str, config: Dict[str, Any]):
        """
        Cria uma instância do engine TTS apropriado.
        
        Args:
            engine_type: Tipo do engine ('edge', 'coqui', 'piper')
            config: Configuração específica do engine
            
        Returns:
            Instância do engine TTS
            
        Raises:
            ValueError: Se o tipo de engine não for suportado
        """
        if engine_type not in self._engines:
            raise ValueError(f"Engine não suportado: {engine_type}")
        
        engine_class = self._engines[engine_type]
        return engine_class(config)
    
    def get_supported_engines(self) -> list:
        """
        Retorna lista de engines suportados.
        
        Returns:
            Lista com nomes dos engines suportados
        """
        return list(self._engines.keys())
    
    def is_engine_available(self, engine_type: str) -> bool:
        """
        Verifica se um engine está disponível (dependências instaladas).
        
        Args:
            engine_type: Tipo do engine para verificar
            
        Returns:
            True se o engine estiver disponível
        """
        try:
            if engine_type == 'edge':
                import edge_tts
                return True
            elif engine_type == 'coqui':
                import TTS
                return True
            elif engine_type == 'piper':
                # Verifica se há modelos disponíveis
                from pathlib import Path
                models_dir = Path("./models")
                return models_dir.exists() and list(models_dir.glob("*.onnx"))
            return False
        except ImportError:
            return False