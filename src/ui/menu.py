"""
src/ui/menu.py

Interface de menu completa com preview, download e correções Edge-TTS.
"""

import asyncio
import sys
import os
import requests
import tarfile
from pathlib import Path
from typing import Tuple, Optional

# Imports relativos para config
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from config import EDGE_VOICES, COQUI_MODELS
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

# Configurações Piper
PIPER_MODELS_DETAILED = {
    "pt_BR-faber-medium.onnx": {
        "name": "Faber", "gender": "Masculino", "quality": "Médio",
        "description": "Voz masculina natural ⭐", "size_mb": 63,
        "url": "https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-medium.tar.gz"
    },
    "pt_BR-faber-low.onnx": {
        "name": "Faber", "gender": "Masculino", "quality": "Baixo", 
        "description": "Voz masculina rápida", "size_mb": 20,
        "url": "https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-low.tar.gz"
    }
}


class MenuInterface:
    """Interface de menu completa."""
    
    def __init__(self):
        self.tts_factory = TTSFactory()
        self.models_dir = Path("./models")
        self.models_dir.mkdir(exist_ok=True)
    
    def show_engine_menu(self) -> str:
        """Menu principal."""
        print("\n" + "="*60)
        print("🎙️ SELEÇÃO DE ENGINE TTS")
        print("="*60)
        
        available_engines = []
        
        # Edge-TTS
        if self.tts_factory.is_engine_available('edge'):
            available_engines.append('edge')
            print("1️⃣ Edge-TTS (Microsoft)")
            print("    🌐 Online | ⚡ Rápido | 🎯 15 vozes PT-BR")
        else:
            print("1️⃣ Edge-TTS - ❌ pip install edge-tts")
        
        print()
        
        # Coqui TTS
        if self.tts_factory.is_engine_available('coqui'):
            available_engines.append('coqui')
            print("2️⃣ Coqui TTS")
            print("    🔒 100% Local | 🤖 IA | 🎭 Clonagem")
        else:
            print("2️⃣ Coqui TTS - ❌ pip install TTS")
        
        print()
        
        # Piper TTS
        local_models = list(self.models_dir.glob("*.onnx"))
        if local_models:
            available_engines.append('piper')
            print("3️⃣ Piper TTS")
            print(f"    🔧 Local | ⚡ Rápido | 📁 {len(local_models)} modelos")
        else:
            print("3️⃣ Piper TTS - ❌ Baixe modelos")
        
        print("\n🔧 EXTRAS:")
        print("  4️⃣ 📥 Download Piper")
        print("  5️⃣ 🎧 Testar vozes")
        print("  6️⃣ ❌ Sair")
        
        if not available_engines:
            print("\n❌ Nenhum engine disponível!")
            sys.exit(1)
        
        choice = self._get_choice("Escolha (1-6)", 6)
        
        if choice == 1 and 'edge' in available_engines:
            return "edge"
        elif choice == 2 and 'coqui' in available_engines:
            return "coqui"
        elif choice == 3 and 'piper' in available_engines:
            return "piper"
        elif choice == 4:
            self.download_piper_models()
            return self.show_engine_menu()
        elif choice == 5:
            self._test_all_voices()
            return self.show_engine_menu()
        else:
            sys.exit(0)
    
    def get_edge_voice(self) -> str:
        """Menu Edge-TTS."""
        print("\n" + "="*70)
        print("🎭 SELEÇÃO DE VOZ (Edge-TTS)")
        print("="*70)
        print("👩 FEMININAS:")
        for num in ["1", "2", "3", "4", "5", "6", "7", "8"]:
            voice_id, description = EDGE_VOICES[num]
            print(f"  {num:>2}️⃣ {description}")
        
        print("\n👨 MASCULINAS:")
        for num in ["9", "10", "11", "12", "13", "14", "15"]:
            voice_id, description = EDGE_VOICES[num]
            print(f"  {num:>2}️⃣ {description}")
        
        print("\n🎵 OPÇÕES:")
        print("  16️⃣ 🎧 Testar todas")
        print("  17️⃣ 🔙 Voltar")
        print("="*70)
        
        choice = self._get_choice("Voz (1-17, padrão=1)", 17, default=1)
        
        if choice <= 15:
            voice_id, description = EDGE_VOICES[str(choice)]
            print(f"\n🎵 Selecionada: {description}")
            
            if self._confirm("🎧 Testar?"):
                print("🎵 Gerando preview...")
                self._preview_edge_voice(voice_id)
            
            return voice_id
        elif choice == 16:
            self._test_all_edge_voices()
            return self.get_edge_voice()
        else:
            return self.show_engine_menu()
    
    def get_coqui_model(self) -> Tuple[str, Optional[str]]:
        """Menu Coqui TTS."""
        print("\n" + "="*70)
        print("🤖 SELEÇÃO DE MODELO (Coqui TTS)")
        print("="*70)
        
        for num, (model_id, name, description, has_speakers) in COQUI_MODELS.items():
            print(f"{num}️⃣ {name}")
            print(f"    📝 {description}")
            if has_speakers:
                print(f"    🎭 Múltiplas vozes")
            print()
        
        print("="*70)
        
        choice = self._get_choice("Modelo (1-4, padrão=1)", 4, default=1)
        
        if choice in range(1, 5):
            model_id, name, description, has_speakers = COQUI_MODELS[str(choice)]
            print(f"\n🤖 Selecionado: {name}")
            
            speaker = None
            if has_speakers:
                speaker = self._get_coqui_speaker(model_id)
            
            if self._confirm("🎧 Testar?"):
                print("🎵 Gerando exemplo...")
                self._preview_coqui_voice(model_id, speaker)
            
            return model_id, speaker
        
        return self.get_coqui_model()
    
    def get_piper_model(self) -> Path:
        """Menu Piper TTS."""
        print("\n" + "="*70)
        print("🔧 SELEÇÃO DE MODELO PIPER")
        print("="*70)
        
        # Modelos locais
        local_models = {}
        for i, onnx_file in enumerate(self.models_dir.glob("*.onnx"), 1):
            model_name = onnx_file.name
            info = PIPER_MODELS_DETAILED.get(model_name, {
                "name": "Personalizado", "gender": "?", 
                "quality": "?", "description": "Modelo personalizado"
            })
            
            local_models[str(i)] = (onnx_file, info)
            
            gender_icon = "👨" if info['gender'] == "Masculino" else "👩" if info['gender'] == "Feminino" else "🤖"
            star = " ⭐" if "⭐" in info['description'] else ""
            size_mb = onnx_file.stat().st_size / 1024 / 1024
            
            print(f"  {i:>2}️⃣ {gender_icon} {info['name']} - {info['description']}{star}")
            print(f"      📊 {info['quality']} | {size_mb:.1f}MB")
        
        if not local_models:
            print("❌ Nenhum modelo em ./models/")
            print("\n💡 OPÇÕES:")
            print("  1️⃣ 📥 Download automático")
            print("  2️⃣ 🔙 Voltar")
            
            choice = self._get_choice("Opção (1-2)", 2)
            if choice == 1:
                return self.download_piper_models()
            else:
                return self.get_coqui_model()
        
        # Opções extras
        total_models = len(local_models)
        print(f"\n🎵 OPÇÕES:")
        print(f"  {total_models + 1}️⃣ 🎧 Testar todos")
        print(f"  {total_models + 2}️⃣ 📥 Download mais")
        print(f"  {total_models + 3}️⃣ 🔙 Voltar")
        print("="*70)
        
        choice = self._get_choice(f"Escolha (1-{total_models + 3}, padrão=1)", total_models + 3, default=1)
        
        if 1 <= choice <= total_models:
            model_path, info = local_models[str(choice)]
            print(f"\n🔧 Selecionado: {info['name']}")
            
            if self._confirm("🎧 Testar?"):
                self._preview_piper_voice(model_path)
            
            return model_path
        elif choice == total_models + 1:
            self._test_all_piper_models()
            return self.get_piper_model()
        elif choice == total_models + 2:
            self.download_piper_models()
            return self.get_piper_model()
        else:
            return self.get_coqui_model()
    
    def download_piper_models(self) -> Optional[Path]:
        """Download automático Piper."""
        print("\n" + "="*70)
        print("📥 DOWNLOAD MODELOS PIPER")
        print("="*70)
        
        available_downloads = {}
        counter = 1
        
        for model_name, info in PIPER_MODELS_DETAILED.items():
            model_path = self.models_dir / model_name
            if not model_path.exists():
                available_downloads[str(counter)] = (model_name, info)
                gender_icon = "👨" if info['gender'] == "Masculino" else "👩"
                print(f"  {counter}️⃣ {gender_icon} {info['name']} - {info['description']}")
                print(f"      📊 {info['quality']} | {info['size_mb']}MB")
                counter += 1
        
        if not available_downloads:
            print("✅ Todos os modelos instalados!")
            input("Enter para continuar...")
            return self.get_piper_model()
        
        print(f"\n  {counter}️⃣ 📦 Baixar todos")
        print(f"  {counter + 1}️⃣ 🔙 Cancelar")
        print("="*70)
        
        choice = self._get_choice(f"Escolha (1-{counter + 1})", counter + 1)
        
        if 1 <= choice <= len(available_downloads):
            model_name, info = available_downloads[str(choice)]
            print(f"\n📥 Baixando {model_name}...")
            
            if self._download_single_model(model_name, info):
                model_path = self.models_dir / model_name
                print(f"✅ {model_name} instalado!")
                
                if self._confirm("🎧 Testar?"):
                    self._preview_piper_voice(model_path)
                
                return model_path
            else:
                print("❌ Falha no download")
                
        elif choice == counter:
            print("📦 Baixando todos...")
            self._download_all_models()
            
        return self.get_piper_model()
    
    def _download_single_model(self, model_name: str, info: dict) -> bool:
        """Download de modelo específico."""
        try:
            url = info.get('url')
            if not url:
                print(f"❌ URL não disponível")
                return False
            
            # Download
            print(f"🌐 Conectando...")
            response = requests.get(url, stream=True)
            response.raise_for_status()
            
            tar_path = self.models_dir / f"{model_name}.tar.gz"
            total_size = int(response.headers.get('content-length', 0))
            downloaded = 0
            
            with open(tar_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)
                        
                        if total_size > 0:
                            progress = (downloaded / total_size) * 100
                            bar_length = 30
                            filled = int(bar_length * downloaded // total_size)
                            bar = '█' * filled + '░' * (bar_length - filled)
                            print(f"\r📊 [{bar}] {progress:.1f}%", end='', flush=True)
            
            print()
            
            # Extração
            print(f"📦 Extraindo...")
            with tarfile.open(tar_path, 'r:gz') as tar:
                tar.extractall(self.models_dir)
            
            tar_path.unlink()
            
            model_path = self.models_dir / model_name
            return model_path.exists()
            
        except Exception as e:
            print(f"❌ Erro: {e}")
            return False
    
    def _get_choice(self, prompt: str, max_choice: int, default: Optional[int] = None) -> int:
        """Obtém escolha do usuário."""
        while True:
            try:
                default_text = f", padrão={default}" if default else ""
                choice = input(f"\n🎯 {prompt}{default_text}: ").strip()
                
                if not choice and default:
                    return default
                
                choice_num = int(choice)
                if 1 <= choice_num <= max_choice:
                    return choice_num
                else:
                    print(f"❌ Digite 1-{max_choice}")
            except ValueError:
                print("❌ Digite um número")
            except KeyboardInterrupt:
                print("\n👋 Cancelado")
                sys.exit(0)
    
    def _confirm(self, question: str, default_yes: bool = True) -> bool:
        """Confirmação."""
        suffix = "(S/n)" if default_yes else "(s/N)"
        answer = input(f"{question} {suffix}: ").strip().lower()
        return answer in ['s', 'sim', 'y', 'yes'] if answer else default_yes
    
    def _preview_edge_voice(self, voice: str):
        """Preview Edge-TTS com retry."""
        if not edge_tts:
            print("❌ Edge-TTS não disponível")
            return
        
        async def preview_with_retry():
            preview_file = Path(f".preview-{voice.split('-')[-1]}.mp3")
            
            # Textos alternativos
            attempts = [
                "Olá, demonstração da voz selecionada.",
                "Esta é uma demonstração.",
                "Teste de voz."
            ]
            
            for attempt, test_text in enumerate(attempts, 1):
                try:
                    print(f"🎵 Tentativa {attempt}...")
                    communicate = edge_tts.Communicate(test_text, voice)
                    await communicate.save(str(preview_file))
                    
                    # Verifica arquivo
                    if preview_file.exists() and preview_file.stat().st_size > 1000:
                        self._play_audio(preview_file)
                        return
                    else:
                        if preview_file.exists():
                            preview_file.unlink()
                        
                except Exception as e:
                    print(f"   ❌ Falhou: {e}")
                    if preview_file.exists():
                        preview_file.unlink()
                    
                    if attempt < len(attempts):
                        await asyncio.sleep(1)
            
            print(f"❌ Todas as tentativas falharam")
        
        asyncio.run(preview_with_retry())
    
    def _preview_piper_voice(self, model_path: Path):
        """Preview Piper."""
        import subprocess
        
        text = "Esta é uma demonstração do modelo Piper."
        preview_file = Path(f".preview-piper-{model_path.stem}.wav")
        
        cmd = ["piper", "--model", str(model_path), "--output_file", str(preview_file)]
        
        try:
            result = subprocess.run(cmd, input=text, text=True, capture_output=True, timeout=30)
            if result.returncode == 0:
                self._play_audio(preview_file)
            else:
                print(f"❌ Erro: {result.stderr}")
        except Exception as e:
            print(f"❌ Erro: {e}")
    
    def _play_audio(self, file: Path):
        """Reproduz áudio."""
        import subprocess
        try:
            if sys.platform == "darwin":
                subprocess.run(["afplay", str(file)], check=False)
            elif sys.platform.startswith("linux"):
                subprocess.run(["aplay", str(file)], check=False)
            else:
                print(f"🎵 Salvo: {file}")
        except:
            print(f"🎵 Salvo: {file}")
    
    def _test_all_edge_voices(self):
        """Testa todas as vozes Edge."""
        print("\n🎧 TESTANDO TODAS AS VOZES...")
        for i in range(1, 16):
            voice_id, desc = EDGE_VOICES[str(i)]
            name = desc.split(' - ')[0]
            if self._confirm(f"Testar {name}?", False):
                self._preview_edge_voice(voice_id)
                input("Enter para continuar...")
    
    def _test_all_piper_models(self):
        """Testa todos os modelos Piper."""
        print("\n🎧 TESTANDO MODELOS PIPER...")
        for model_path in self.models_dir.glob("*.onnx"):
            if self._confirm(f"Testar {model_path.stem}?", False):
                self._preview_piper_voice(model_path)
                input("Enter para continuar...")
    
    # Métodos placeholder
    def _get_coqui_speaker(self, model_id: str): 
        return None
    
    def _preview_coqui_voice(self, model_id: str, speaker=None): 
        pass
    
    def _download_all_models(self): 
        pass
    
    def _test_all_voices(self): 
        pass