# -*- coding: utf-8 -*-
"""
Menu interativo para seleção de engines TTS e vozes
Implementa padrão Strategy para seleção de engines
"""

from abc import ABC, abstractmethod
from typing import List, Dict, Any, Optional, Tuple
from dataclasses import dataclass
from ..config import Config


@dataclass
class EngineOption:
    """Opção de engine TTS com metadados"""
    name: str
    display_name: str
    description: str
    requires_internet: bool
    quality: str  # "high", "medium", "low"
    speed: str    # "fast", "medium", "slow"
    voices: List[str]


class MenuDisplayStrategy(ABC):
    """Strategy para diferentes tipos de display de menu"""
    
    @abstractmethod
    def display_engines(self, engines: List[EngineOption]) -> None:
        pass
    
    @abstractmethod
    def display_voices(self, engine_name: str, voices: List[str]) -> None:
        pass
    
    @abstractmethod
    def get_user_input(self, prompt: str, max_value: int) -> int:
        pass


class InteractiveMenuDisplay(MenuDisplayStrategy):
    """Display interativo colorido para terminal"""
    
    def display_engines(self, engines: List[EngineOption]) -> None:
        print("\n" + "="*60)
        print("🎵 ESCOLHA O ENGINE TTS")
        print("="*60)
        
        for i, engine in enumerate(engines, 1):
            status_icon = "🌐" if engine.requires_internet else "💻"
            quality_icon = self._get_quality_icon(engine.quality)
            speed_icon = self._get_speed_icon(engine.speed)
            
            print(f"{i:2d}. {status_icon} {engine.display_name}")
            print(f"    {quality_icon} Qualidade: {engine.quality.title()}")
            print(f"    {speed_icon} Velocidade: {engine.speed.title()}")
            print(f"    📝 {engine.description}")
            print(f"    🎙️  {len(engine.voices)} vozes disponíveis")
            print()
    
    def display_voices(self, engine_name: str, voices: List[str]) -> None:
        print(f"\n🎙️  VOZES DISPONÍVEIS - {engine_name}")
        print("="*60)
        
        for i, voice in enumerate(voices, 1):
            # Parse voice info
            voice_info = self._parse_voice_info(voice)
            print(f"{i:2d}. {voice_info['flag']} {voice_info['name']}")
            if voice_info['description']:
                print(f"    💭 {voice_info['description']}")
        print()
    
    def get_user_input(self, prompt: str, max_value: int) -> int:
        while True:
            try:
                choice = input(f"{prompt} (1-{max_value}): ").strip()
                if choice.isdigit():
                    choice_int = int(choice)
                    if 1 <= choice_int <= max_value:
                        return choice_int
                print(f"❌ Digite um número entre 1 e {max_value}")
            except KeyboardInterrupt:
                print("\n\n👋 Cancelado pelo usuário")
                raise SystemExit(0)
            except Exception:
                print(f"❌ Digite um número válido entre 1 e {max_value}")
    
    def _get_quality_icon(self, quality: str) -> str:
        icons = {"high": "⭐⭐⭐", "medium": "⭐⭐", "low": "⭐"}
        return icons.get(quality, "⭐")
    
    def _get_speed_icon(self, speed: str) -> str:
        icons = {"fast": "🚀", "medium": "🚶", "slow": "🐌"}
        return icons.get(speed, "🚶")
    
    def _parse_voice_info(self, voice: str) -> Dict[str, str]:
        """Parse informações da voz para display bonito"""
        voice_lower = voice.lower()
        
        # Detecta país/região pela voz
        if 'br' in voice_lower or 'brazil' in voice_lower:
            flag = "🇧🇷"
            country = "Brasil"
        elif 'pt' in voice_lower or 'portugal' in voice_lower:
            flag = "🇵🇹"
            country = "Portugal"
        else:
            flag = "🎙️"
            country = ""
        
        # Detecta gênero
        if any(name in voice_lower for name in ['antonio', 'francisco', 'daniel', 'giovanni']):
            gender = "👨 Masculina"
        elif any(name in voice_lower for name in ['francisca', 'maria', 'ines', 'fernanda']):
            gender = "👩 Feminina"
        else:
            gender = ""
        
        # Monta descrição
        description_parts = [country, gender]
        description = " • ".join(filter(None, description_parts))
        
        return {
            'flag': flag,
            'name': voice,
            'description': description
        }


class TTSMenuService:
    """Serviço principal do menu TTS seguindo princípios SOLID"""
    
    def __init__(self, display_strategy: MenuDisplayStrategy = None):
        self.display = display_strategy or InteractiveMenuDisplay()
        self.config = Config()
        self._engines = self._build_engine_options()
    
    def _build_engine_options(self) -> List[EngineOption]:
        """Constrói opções de engines baseado na configuração"""
        engines = []
        
        # Edge-TTS
        engines.append(EngineOption(
            name="edge",
            display_name="Microsoft Edge-TTS",
            description="Vozes naturais da Microsoft (online)",
            requires_internet=True,
            quality="high",
            speed="fast",
            voices=list(self.config.edge_voices.keys())
        ))
        
        # Coqui TTS
        engines.append(EngineOption(
            name="coqui",
            display_name="Coqui TTS (AI Local)",
            description="IA Neural local com clonagem de voz",
            requires_internet=False,
            quality="high",
            speed="slow",
            voices=list(self.config.coqui_models.keys())
        ))
        
        # Piper TTS
        engines.append(EngineOption(
            name="piper",
            display_name="Piper TTS (Local)",
            description="Engine leve e rápido para uso local",
            requires_internet=False,
            quality="medium",
            speed="medium",
            voices=list(self.config.piper_models.keys())
        ))
        
        return engines
    
    def show_menu(self) -> Tuple[str, str]:
        """Mostra menu e retorna (engine, voice) selecionados"""
        
        # Seleção do engine
        self.display.display_engines(self._engines)
        engine_choice = self.display.get_user_input("🎯 Escolha o engine", len(self._engines))
        selected_engine = self._engines[engine_choice - 1]
        
        # Seleção da voz
        self.display.display_voices(selected_engine.display_name, selected_engine.voices)
        voice_choice = self.display.get_user_input("🎙️  Escolha a voz", len(selected_engine.voices))
        selected_voice = selected_engine.voices[voice_choice - 1]
        
        # Confirmação
        print(f"\n✅ SELEÇÃO CONFIRMADA:")
        print(f"🎵 Engine: {selected_engine.display_name}")
        print(f"🎙️  Voz: {selected_voice}")
        print("="*60)
        
        return selected_engine.name, selected_voice
    
    def get_engine_info(self, engine_name: str) -> Optional[EngineOption]:
        """Retorna informações de um engine específico"""
        for engine in self._engines:
            if engine.name == engine_name:
                return engine
        return None


# Função de conveniência para compatibilidade
def show_tts_menu() -> Tuple[str, str]:
    """Mostra menu TTS e retorna (engine, voice)"""
    menu = TTSMenuService()
    return menu.show_menu()


def show_quick_menu(engine: str = None, voice: str = None) -> Tuple[str, str]:
    """Menu rápido com valores padrão"""
    if engine and voice:
        print(f"🎵 Usando: {engine} - {voice}")
        return engine, voice
    
    return show_tts_menu()