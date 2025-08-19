# debug_xtts_audio.py
from TTS.api import TTS
import os
import sys
import subprocess
import platform

def play_audio(file_path):
    """Reproduz arquivo de áudio automaticamente."""
    if not os.path.exists(file_path):
        print(f"❌ Arquivo não encontrado: {file_path}")
        return
    
    try:
        system = platform.system().lower()
        
        if system == "darwin":  # macOS
            subprocess.run(["afplay", file_path], check=False)
            print(f"🎵 Reproduzindo no macOS: {file_path}")
        elif system == "linux":  # Linux
            # Tenta diferentes players
            players = ["aplay", "paplay", "mpv", "vlc"]
            for player in players:
                try:
                    subprocess.run([player, file_path], check=True, capture_output=True)
                    print(f"🎵 Reproduzindo no Linux com {player}: {file_path}")
                    break
                except (subprocess.CalledProcessError, FileNotFoundError):
                    continue
            else:
                print(f"⚠️ Nenhum player encontrado no Linux. Arquivo salvo: {file_path}")
        elif system == "windows":  # Windows
            os.startfile(file_path)
            print(f"🎵 Abrindo no Windows: {file_path}")
        else:
            print(f"🎵 Sistema desconhecido. Arquivo salvo: {file_path}")
            
    except Exception as e:
        print(f"⚠️ Erro ao reproduzir áudio: {e}")
        print(f"📁 Arquivo salvo manualmente: {file_path}")

def test_xtts():
    print("🔄 Carregando modelo XTTS v2...")
    
    try:
        tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2")
        print("✅ Modelo carregado com sucesso!")
        
        # Lista speakers disponíveis
        if hasattr(tts, 'speakers') and tts.speakers:
            print(f"📢 {len(tts.speakers)} speakers disponíveis:")
            for i, speaker in enumerate(tts.speakers[:5], 1):  # Mostra primeiros 5
                print(f"  {i}. {speaker}")
            if len(tts.speakers) > 5:
                print(f"  ... e mais {len(tts.speakers) - 5} speakers")
            
            # Teste com primeiro speaker
            first_speaker = tts.speakers[0]
            print(f"\n🎤 Testando com speaker: {first_speaker}")
            
            test_file = "teste_speaker_auto.wav"
            tts.tts_to_file(
                text="Olá! Este é um teste do XTTS versão 2 em português brasileiro. A qualidade da voz está muito boa!",
                file_path=test_file,
                speaker=first_speaker,
                language="pt"
            )
            print(f"✅ Arquivo gerado: {test_file}")
            
            # Reproduz automaticamente
            play_audio(test_file)
            
        else:
            print("⚠️ Nenhum speaker pré-definido encontrado")
        
        # Teste com voice cloning se arquivo existir
        if os.path.exists("reference_voice.wav"):
            print("\n🎤 Testando voice cloning...")
            
            clone_file = "teste_clonado_auto.wav"
            tts.tts_to_file(
                text="Este é um teste de clonagem de voz usando o XTTS. Sua voz foi clonada com sucesso!",
                file_path=clone_file,
                speaker_wav="reference_voice.wav",
                language="pt"
            )
            print(f"✅ Arquivo clonado gerado: {clone_file}")
            
            # Reproduz voz clonada
            play_audio(clone_file)
            
        else:
            print("\n💡 Para testar voice cloning:")
            print("   1. Grave sua voz por 6-10 segundos")
            print("   2. Salve como 'reference_voice.wav'")
            print("   3. Execute o script novamente")
        
        print(f"\n🎯 Teste concluído! Arquivos gerados:")
        for file in ["teste_speaker_auto.wav", "teste_clonado_auto.wav"]:
            if os.path.exists(file):
                size = os.path.getsize(file) / 1024  # KB
                print(f"   📁 {file} ({size:.1f} KB)")
                
    except Exception as e:
        print(f"❌ Erro: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    print("🐸 TESTE DEBUG XTTS v2 COM REPRODUÇÃO DE ÁUDIO")
    print("=" * 50)
    test_xtts()
    print("=" * 50)
    print("✨ Teste finalizado!")