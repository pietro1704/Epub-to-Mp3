# debug_xtts.py
from TTS.api import TTS
import os

def test_xtts():
    print("🔄 Carregando modelo XTTS v2...")
    
    try:
        tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2")
        print("✅ Modelo carregado com sucesso!")
        
        # Lista speakers disponíveis
        if hasattr(tts, 'speakers') and tts.speakers:
            print(f"📢 Speakers disponíveis: {tts.speakers}")
            
            # Teste com primeiro speaker
            first_speaker = tts.speakers[0] if tts.speakers else None
            if first_speaker:
                print(f"🎤 Testando com speaker: {first_speaker}")
                tts.tts_to_file(
                    text="Teste em português brasileiro.",
                    file_path="teste_speaker_auto.wav",
                    speaker=first_speaker,
                    language="pt"
                )
                print("✅ Arquivo gerado com speaker pré-definido!")
        else:
            print("⚠️ Nenhum speaker pré-definido encontrado")
        
        # Teste com voice cloning se arquivo existir
        if os.path.exists("reference_voice.wav"):
            print("🎤 Testando voice cloning...")
            tts.tts_to_file(
                text="Teste de clonagem de voz em português.",
                file_path="teste_clonado_auto.wav",
                speaker_wav="reference_voice.wav",
                language="pt"
            )
            print("✅ Arquivo gerado com voice cloning!")
        else:
            print("💡 Para testar voice cloning, crie um 'reference_voice.wav'")
            
    except Exception as e:
        print(f"❌ Erro: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test_xtts()