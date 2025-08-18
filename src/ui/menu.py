"""
src/ui/menu.py

Interface de menu para seleção de engines e configurações.
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
        Permite selecionar modelo do Coqui TTS com suporte PT-BR.
        
        Returns:
            Tupla com (model_name, speaker)
        """
        print("\n" + "=" * 70)
        print("🤖 SELEÇÃO DE MODELO (Coqui TTS)")
        print("=" * 70)
        
        for num, (model_id, name, description, has_speakers) in COQUI_MODELS.items():
            print(f"{num}️⃣ {name}")
            print(f"    📝 {description}")
            if has_speakers:
                print(f"    🎭 Múltiplas vozes disponíveis")
            print()
        
        print("=" * 70)
        
        while True:
            try:
                choice = input("🎯 Escolha o modelo (1-4, padrão=1): ").strip()
                if not choice:
                    choice = "1"
                
                if choice in COQUI_MODELS:
                    model_id, name, description, has_speakers = COQUI_MODELS[choice]
                    print(f"\n🤖 Modelo selecionado: {name}")
                    print(f"📝 {description}")
                    
                    # Seleção de speaker se disponível
                    speaker = None
                    if has_speakers:
                        speaker = self._get_coqui_speaker(model_id)
                    
                    # Oferece preview
                    preview = input("\n🎧 Quer ouvir um exemplo? (s/N): ").strip().lower()
                    if preview in ['s', 'sim', 'y', 'yes']:
                        print("🎵 Gerando exemplo (pode demorar na primeira vez)...")
                        self._preview_coqui_voice(model_id, speaker)
                    
                    return model_id, speaker
                else:
                    print("❌ Opção inválida!")
                    
            except KeyboardInterrupt:
                print("\n\n👋 Cancelado pelo usuário")
                sys.exit(0)
    
    def _get_coqui_speaker(self, model_id: str) -> Optional[str]:
        """Obtém speaker para modelo Coqui."""
        # XTTS v2 funciona diferente - usa clonagem de voz
        if "xtts_v2" in model_id.lower():
            return self._handle_xtts_v2_speaker()
        
        # Outros modelos com speakers pré-definidos
        return self._handle_regular_coqui_speakers(model_id)
    
    def _handle_xtts_v2_speaker(self) -> Optional[str]:
        """Manipula seleção de speaker para XTTS v2."""
        print("\n🎭 XTTS v2 - Vozes Nativas Português Brasil")
        print("📢 XTTS v2 foi treinado com 2.386 horas de dados PT-BR nativos!")
        print("💡 Para clonar sua voz: coloque um arquivo .wav de 6-10 segundos em ./reference_voice.wav")
        
        ref_voice = Path("./reference_voice.wav")
        if ref_voice.exists():
            print(f"✅ Voz de referência encontrada: {ref_voice}")
            use_ref = input("🎯 Usar esta voz de referência? (S/n): ").strip().lower()
            if use_ref not in ['n', 'no', 'não']:
                return str(ref_voice)
        
        print("\n🎭 Vozes nativas disponíveis (já falam português naturalmente):")
        print("1️⃣ Ana Florence (Feminina, brasileira)")
        print("2️⃣ Claribel Dervla (Feminina, portuguesa)")  
        print("3️⃣ Tammie Ema (Feminina, neutra)")
        print("4️⃣ Andrew Chipper (Masculina, clara)")
        print("5️⃣ Badr Odhiambo (Masculina, grave)")
        print("6️⃣ Viktor Eka (Masculina, jovem)")
        print("7️⃣ Usar modelo F5-TTS nativo PT-BR (100% brasileiro)")
        
        voice_map = {
            "1": "Ana Florence",
            "2": "Claribel Dervla", 
            "3": "Tammie Ema",
            "4": "Andrew Chipper",
            "5": "Badr Odhiambo",
            "6": "Viktor Eka",
            "7": "F5-TTS-PT-BR"
        }
        
        choice = input("🎯 Escolha uma voz (1-7, padrão=1): ").strip()
        if not choice:
            choice = "1"
            
        if choice == "7":
            print("🇧🇷 Modelo F5-TTS nativo PT-BR selecionado")
            print("💡 Instale com: pip install f5-tts")
            return "F5-TTS-PT-BR"
        
        selected_voice = voice_map.get(choice, "Ana Florence")
        print(f"📢 Voz selecionada: {selected_voice} (fala português nativo)")
        return selected_voice
    
    def _handle_regular_coqui_speakers(self, model_id: str) -> Optional[str]:
        """Manipula speakers para modelos Coqui regulares."""
        print("\n🎭 Carregando vozes disponíveis...")
        try:
            tts = CoquiTTS(model_name=model_id)
            if hasattr(tts, 'speakers') and tts.speakers:
                print(f"📢 {len(tts.speakers)} vozes disponíveis:")
                
                # Filtra speakers PT-BR se possível
                pt_speakers = [s for s in tts.speakers if 'pt' in s.lower() or 'brazil' in s.lower() or 'BR' in s]
                if not pt_speakers:
                    pt_speakers = tts.speakers[:10]  # Pega primeiros 10
                
                for i, spk in enumerate(pt_speakers, 1):
                    print(f"  {i}. {spk}")
                
                spk_choice = input(f"\n🎯 Escolha a voz (1-{len(pt_speakers)}, Enter=primeira): ").strip()
                if spk_choice and spk_choice.isdigit():
                    idx = int(spk_choice) - 1
                    if 0 <= idx < len(pt_speakers):
                        speaker = pt_speakers[idx]
                        print(f"📢 Voz selecionada: {speaker}")
                        return speaker
                
                speaker = pt_speakers[0]
                print(f"📢 Usando voz padrão: {speaker}")
                return speaker
            else:
                print("⚠️ Modelo não tem vozes pré-definidas")
                return None
                
        except Exception as e:
            print(f"⚠️ Não foi possível carregar vozes: {e}")
            return None
    
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
    
    def _preview_coqui_voice(self, model_name: str, speaker: Optional[str] = None) -> None:
        """Gera preview da voz Coqui."""
        if not TTS:
            return
        
        preview_text = "Olá, esta é uma demonstração da voz selecionada em português brasileiro."
        preview_file = Path(".preview-coqui.wav")
        
        try:
            tts = CoquiTTS(model_name=model_name)
            
            # Para XTTS v2, sempre usar um speaker
            if "xtts" in model_name.lower():
                if not speaker:
                    speaker = "Claribel Dervla"  # Speaker padrão
                    print(f"   📢 Usando voz padrão: {speaker}")
                
                if speaker.endswith('.wav'):
                    # Arquivo de voz de referência
                    tts.tts_to_file(
                        text=preview_text, 
                        file_path=str(preview_file), 
                        speaker_wav=speaker,
                        language="pt"
                    )
                else:
                    # Speaker pré-definido
                    tts.tts_to_file(
                        text=preview_text, 
                        file_path=str(preview_file), 
                        speaker=speaker,
                        language="pt"
                    )
            else:
                # Outros modelos
                if speaker and hasattr(tts, 'speakers') and tts.speakers:
                    tts.tts_to_file(text=preview_text, file_path=str(preview_file), speaker=speaker)
                else:
                    tts.tts_to_file(text=preview_text, file_path=str(preview_file))
            
            self._play_audio(preview_file)
            
        except Exception as e:
            print(f"❌ Erro ao gerar preview Coqui: {e}")
            print("💡 Dica: Isso é normal na primeira execução. O modelo será baixado durante a conversão.")
    
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