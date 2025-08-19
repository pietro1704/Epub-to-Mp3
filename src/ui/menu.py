"""
src/ui/menu.py

Interface de menu com Coqui TTS SIMPLIFICADO para evitar erros.
"""

import asyncio
import sys
from pathlib import Path
from typing import Tuple, Optional

# Imports relativos para config
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from config import EDGE_VOICES, COQUI_MODELS, KNOWN_PIPER_MODELS
from tts_factory import TTSFactory

try:
    import edge_tts
except ImportError:
    edge_tts = None

try:
    import TTS
    from TTS.api import TTS as CoquiTTS
except ImportError:
    TTS = None
    CoquiTTS = None


class MenuInterface:
    """Interface de menu para interação com o usuário."""
    
    def __init__(self):
        """Inicializa a interface de menu."""
        self.tts_factory = TTSFactory()
    
    def show_engine_menu(self) -> str:
        """
        Mostra menu de seleção de engine TTS.
        
        Returns:
            Engine selecionado ('edge', 'coqui', 'piper')
        """
        print("\n" + "=" * 60)
        print("🎙️ SELEÇÃO DE ENGINE TTS")
        print("=" * 60)
        
        available_engines = []
        
        # Edge-TTS
        if self.tts_factory.is_engine_available('edge'):
            available_engines.append('edge')
            print("1️⃣ Edge-TTS (Microsoft)")
            print("    🌐 Online (Microsoft processa o texto)")
            print("    ⚡ Muito rápido | 🎯 Boa qualidade | 💰 Gratuito")
        else:
            print("1️⃣ Edge-TTS (Microsoft) - ❌ Não instalado")
            print("    Execute: pip install edge-tts")
        
        print()
        
        # Coqui TTS
        if self.tts_factory.is_engine_available('coqui'):
            available_engines.append('coqui')
            print("2️⃣ Coqui TTS")
            print("    🔒 100% Local (seus dados não saem do computador)")
            print("    🐌 Mais lento | 🎯 Boa qualidade | 💰 Gratuito")
        else:
            print("2️⃣ Coqui TTS - ❌ Não instalado")
            print("    Execute: pip install TTS")
        
        print()
        
        # Piper
        if self.tts_factory.is_engine_available('piper'):
            available_engines.append('piper')
            models_dir = Path("./models")
            model_count = len(list(models_dir.glob("*.onnx")))
            print("3️⃣ Piper")
            print("    🔧 100% Local | ⚡ Rápido | 🎯 Qualidade boa")
            print(f"    📁 {model_count} modelo(s) encontrado(s)")
        else:
            print("3️⃣ Piper - ❌ Nenhum modelo encontrado")
            print("    Baixe modelos .onnx em: ./models/")
            print("    https://github.com/rhasspy/piper/releases")
        
        print("\n" + "=" * 60)
        print("🔐 PRIVACIDADE:")
        print("   Edge-TTS: Microsoft processa seu texto online")
        print("   Coqui/Piper: 100% local, seus dados não saem do PC")
        print("=" * 60)
        
        if not available_engines:
            print("❌ ERRO: Nenhum engine TTS disponível!")
            print("\nInstale pelo menos um:")
            print("• pip install edge-tts  (mais rápido)")
            print("• pip install TTS       (mais privado)")
            sys.exit(1)
        
        return self._get_engine_choice(available_engines)
    
    def _get_engine_choice(self, available_engines: list) -> str:
        """Obtém escolha do usuário para engine."""
        while True:
            try:
                choice = input("\n🎯 Escolha o engine (1-3): ").strip()
                
                if choice == "1" and 'edge' in available_engines:
                    return "edge"
                elif choice == "2" and 'coqui' in available_engines:
                    return "coqui"
                elif choice == "3" and 'piper' in available_engines:
                    return "piper"
                else:
                    print("❌ Opção inválida ou engine não disponível!")
                    
            except KeyboardInterrupt:
                print("\n\n👋 Cancelado pelo usuário")
                sys.exit(0)
    
    def get_edge_voice(self) -> str:
        """
        Permite selecionar voz do Edge-TTS em português.
        
        Returns:
            ID da voz selecionada
        """
        print("\n" + "=" * 70)
        print("🎭 SELEÇÃO DE VOZ (Edge-TTS)")
        print("=" * 70)
        print("👩 VOZES FEMININAS:")
        for num in ["1", "2", "3", "4", "5", "6", "7", "8"]:
            voice_id, description = EDGE_VOICES[num]
            print(f"  {num:>2}️⃣ {description}")
        
        print("\n👨 VOZES MASCULINAS:")
        for num in ["9", "10", "11", "12", "13", "14", "15"]:
            voice_id, description = EDGE_VOICES[num]
            print(f"  {num:>2}️⃣ {description}")
        
        print("=" * 70)
        
        while True:
            try:
                choice = input("\n🎯 Escolha a voz (1-15, padrão=1): ").strip()
                if not choice:
                    choice = "1"
                
                if choice in EDGE_VOICES:
                    voice_id, description = EDGE_VOICES[choice]
                    print(f"\n🎵 Voz selecionada: {description}")
                    
                    # Oferece preview
                    preview = input("🎧 Quer ouvir um exemplo? (s/N): ").strip().lower()
                    if preview in ['s', 'sim', 'y', 'yes']:
                        print("🎵 Gerando exemplo...")
                        self._preview_edge_voice(voice_id)
                    
                    return voice_id
                else:
                    print("❌ Opção inválida! Digite um número de 1 a 15")
                    
            except KeyboardInterrupt:
                print("\n\n👋 Cancelado pelo usuário")
                sys.exit(0)
    
    def get_coqui_model(self) -> Tuple[str, Optional[str]]:
        """
        COQUI TTS SIMPLIFICADO - evita erros de API.
        
        Returns:
            Tupla com (model_name, speaker)
        """
        print("\n" + "=" * 70)
        print("🤖 SELEÇÃO DE MODELO (Coqui TTS)")
        print("=" * 70)
        
        # Modelos simplificados para evitar erros
        simple_models = {
            "1": ("tts_models/multilingual/multi-dataset/xtts_v2", "XTTS v2 (Português)", "⭐ Melhor qualidade, clonagem de voz"),
            "2": ("tts_models/multilingual/multi-dataset/xtts_v1.1", "XTTS v1.1 (Português)", "Boa qualidade, mais estável"),
            "3": ("tts_models/pt/cv/vits", "VITS Português", "Rápido, voz única"),
        }
        
        for num, (model_id, name, description) in simple_models.items():
            print(f"{num}️⃣ {name}")
            print(f"    📝 {description}")
            print()
        
        print("=" * 70)
        print("💡 IMPORTANTE: XTTS usa voz automática ou arquivo de referência")
        print("   Para clonar sua voz: coloque um arquivo .wav em ./reference_voice.wav")
        
        while True:
            try:
                choice = input("🎯 Escolha o modelo (1-3, padrão=1): ").strip()
                if not choice:
                    choice = "1"
                
                if choice in simple_models:
                    model_id, name, description = simple_models[choice]
                    print(f"\n🤖 Modelo selecionado: {name}")
                    print(f"📝 {description}")
                    
                    # Para XTTS, verifica voz de referência
                    speaker = None
                    if "xtts" in model_id.lower():
                        speaker = self._handle_xtts_simple()
                    
                    # Oferece preview SIMPLES
                    preview = input("\n🎧 Quer testar a voz? (s/N): ").strip().lower()
                    if preview in ['s', 'sim', 'y', 'yes']:
                        print("🎵 Testando voz (pode demorar na primeira vez)...")
                        self._preview_coqui_simple(model_id, speaker)
                    
                    return model_id, speaker
                else:
                    print("❌ Opção inválida!")
                    
            except KeyboardInterrupt:
                print("\n\n👋 Cancelado pelo usuário")
                sys.exit(0)
    
    def _handle_xtts_simple(self) -> Optional[str]:
        """Manipulação SIMPLIFICADA do XTTS para evitar erros."""
        # Verifica se há arquivo de referência
        ref_voice = Path("./reference_voice.wav")
        if ref_voice.exists():
            print(f"✅ Voz de referência encontrada: {ref_voice}")
            use_ref = input("🎯 Usar esta voz de referência? (S/n): ").strip().lower()
            if use_ref not in ['n', 'no', 'não']:
                return str(ref_voice)
        
        print("\n🎭 Opções de voz para XTTS:")
        print("1️⃣ Voz automática (deixa o XTTS escolher) ⭐")
        print("2️⃣ Especificar arquivo de voz (.wav)")
        
        choice = input("🎯 Escolha (1-2, padrão=1): ").strip()
        
        if choice == "2":
            voice_file = input("📁 Caminho do arquivo .wav: ").strip()
            if voice_file and Path(voice_file).exists():
                return voice_file
            else:
                print("⚠️ Arquivo não encontrado, usando voz automática")
        
        print("🤖 Usando voz automática do XTTS")
        return None  # None = voz automática
    
    def get_piper_model(self) -> Path:
        """
        Permite selecionar modelo do Piper TTS.
        
        Returns:
            Caminho do modelo selecionado
        """
        models_dir = Path("./models")
        onnx_files = list(models_dir.glob("*.onnx")) if models_dir.exists() else []
        
        print("\n" + "=" * 70)
        print("🔧 SELEÇÃO DE MODELO (Piper TTS)")
        print("=" * 70)
        
        available_models = {}
        counter = 1
        
        for onnx_file in onnx_files:
            model_name = onnx_file.name
            description = KNOWN_PIPER_MODELS.get(model_name, "Modelo personalizado")
            available_models[str(counter)] = (onnx_file, model_name, description)
            print(f"{counter}️⃣ {model_name}")
            print(f"    📝 {description}")
            print(f"    📁 {onnx_file}")
            print()
            counter += 1
        
        if not available_models:
            print("❌ Nenhum modelo .onnx encontrado em ./models/")
            print("\n💡 Download modelos em:")
            print("   https://github.com/rhasspy/piper/releases")
            print("   Exemplo: pt_BR-faber-medium.onnx")
            sys.exit(1)
        
        print("=" * 70)
        
        while True:
            try:
                choice = input(f"🎯 Escolha o modelo (1-{len(available_models)}, padrão=1): ").strip()
                if not choice:
                    choice = "1"
                
                if choice in available_models:
                    model_path, model_name, description = available_models[choice]
                    print(f"\n🔧 Modelo selecionado: {model_name}")
                    print(f"📝 {description}")
                    
                    return model_path
                else:
                    print("❌ Opção inválida!")
                    
            except KeyboardInterrupt:
                print("\n\n👋 Cancelado pelo usuário")
                sys.exit(0)
    
    def _preview_edge_voice(self, voice: str) -> None:
        """Gera preview da voz Edge-TTS."""
        if not edge_tts:
            return
        
        async def preview():
            preview_text = ("Olá, esta é uma demonstração da voz selecionada para o seu "
                           "audiolivro. A qualidade será mantida durante toda a conversão.")
            preview_file = Path(f".preview-{voice.split('-')[-1]}.mp3")
            
            try:
                communicate = edge_tts.Communicate(preview_text, voice)
                await communicate.save(str(preview_file))
                self._play_audio(preview_file)
            except Exception as e:
                print(f"❌ Erro ao gerar preview: {e}")
        
        asyncio.run(preview())
    
    def _preview_coqui_simple(self, model_name: str, speaker: Optional[str] = None) -> None:
        """Preview SIMPLIFICADO do Coqui para evitar erros de API."""
        if not TTS:
            return
        
        preview_text = "Olá, teste de voz."  # Texto MUITO curto para evitar limite
        preview_file = Path(".preview-coqui.wav")
        
        try:
            print("   📥 Carregando modelo...")
            tts = CoquiTTS(model_name=model_name)
            
            is_xtts = "xtts" in model_name.lower()
            
            if is_xtts:
                # XTTS - API SIMPLIFICADA baseada na pesquisa
                if speaker and speaker.endswith('.wav') and Path(speaker).exists():
                    print(f"   🎤 Testando com arquivo: {Path(speaker).name}")
                    tts.tts_to_file(
                        text=preview_text, 
                        file_path=str(preview_file), 
                        speaker_wav=speaker,
                        language="pt"
                    )
                else:
                    print(f"   🎤 Testando voz automática XTTS")
                    # SEM speaker - deixa XTTS escolher (DESCOBERTA DA PESQUISA)
                    tts.tts_to_file(
                        text=preview_text, 
                        file_path=str(preview_file), 
                        language="pt"
                    )
            else:
                # Modelos não-XTTS
                print(f"   🎤 Testando modelo {model_name.split('/')[-1]}")
                tts.tts_to_file(text=preview_text, file_path=str(preview_file))
            
            self._play_audio(preview_file)
            print("✅ Teste concluído com sucesso!")
            
        except Exception as e:
            print(f"❌ Erro no teste: {e}")
            if "character limit" in str(e).lower():
                print("💡 Texto muito longo - será dividido em partes durante a conversão")
            elif "multi-speaker" in str(e).lower():
                print("💡 Será usado sem speaker específico na conversão")
            else:
                print("💡 Isso é normal na primeira execução. O modelo funcionará na conversão.")
    
    def _play_audio(self, audio_file: Path) -> None:
        """Reproduz arquivo de áudio."""
        import subprocess
        
        try:
            if sys.platform == "darwin":
                subprocess.run(["afplay", str(audio_file)], check=False)
            elif sys.platform.startswith("linux"):
                subprocess.run(["aplay", str(audio_file)], check=False)
            else:
                print(f"🎵 Preview salvo em: {audio_file}")
                print("   Reproduza manualmente para ouvir a voz")
        except:
            print(f"🎵 Preview salvo em: {audio_file}")