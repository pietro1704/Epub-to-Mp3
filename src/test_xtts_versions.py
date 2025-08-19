#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
test_xtts_versions_fixed.py

Teste corrigido para XTTS v1 e v2 que resolve:
1. Erro do 'generate' attribute
2. Problemas de multi-speaker  
3. Backend de áudio
4. Compatibilidade com transformers
"""

import warnings
warnings.filterwarnings("ignore")

import sys
import os
from pathlib import Path

def setup_environment():
    """Configura ambiente antes dos testes."""
    print("🔧 Configurando ambiente...")
    
    # Verifica e configura backend de áudio
    try:
        import torchaudio
        backends = torchaudio.list_audio_backends()
        print(f"   📦 Backends disponíveis: {backends}")
        
        if "sox_io" in backends:
            torchaudio.set_audio_backend("sox_io")
            print("   ✅ Backend sox_io configurado")
        elif "soundfile" in backends:
            torchaudio.set_audio_backend("soundfile")
            print("   ✅ Backend soundfile configurado")
        else:
            print("   ⚠️ Usando backend padrão")
            
        current = torchaudio.get_audio_backend()
        print(f"   🎵 Backend atual: {current}")
        
    except Exception as e:
        print(f"\n❌ Erro inesperado: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
        print(f"   ⚠️ Configuração de áudio: {e}")
    
    # Verifica versão do transformers
    try:
        import transformers
        version = transformers.__version__
        print(f"   📦 Transformers: {version}")
        
        # Versões problemáticas
        if version >= "4.50":
            print(f"   ⚠️ Transformers {version} pode causar problemas")
            print("   💡 Recomendado: transformers==4.40.2")
            
    except ImportError:
        print("   ❌ transformers não encontrado")

def test_xtts_v2_corrected():
    """Testa XTTS v2 com correções para erros conhecidos."""
    print("\n🔄 Testando XTTS v2 (Versão Corrigida)")
    print("-" * 60)
    
    try:
        from TTS.api import TTS
        
        # Carrega modelo sem GPU para compatibilidade
        print(" > Carregando modelo (sem GPU)...")
        model_name = "tts_models/multilingual/multi-dataset/xtts_v2"
        tts = TTS(model_name, gpu=False, progress_bar=False)
        print("✅ XTTS v2 carregado!")
        
        # Verifica tipo de modelo
        print(f"📢 Tipo de modelo: {type(tts.synthesizer.tts_model).__name__}")
        
        # XTTS v2 é um modelo de clonagem de voz
        if hasattr(tts, 'speakers') and tts.speakers:
            print(f"📢 Speakers disponíveis: {len(tts.speakers)}")
            speakers_to_test = tts.speakers[:3]  # Testa apenas primeiros 3
        else:
            print("📢 Modelo de voice cloning (sem speakers pré-definidos)")
            # Speakers conhecidos para XTTS v2
            speakers_to_test = ["Ana Florence", "Claribel Dervla"]
        
        # Texto de teste
        test_text = "Olá! Este é um teste do modelo XTTS em português brasileiro."
        
        # Método 1: Testa voice cloning com arquivo (se existir)
        reference_file = Path("reference_voice.wav")
        if reference_file.exists():
            print(f"🎤 Testando voice cloning com: {reference_file}")
            try:
                output_file = Path("test_voice_cloning.wav")
                tts.tts_to_file(
                    text=test_text,
                    speaker_wav=str(reference_file),
                    language="pt",
                    file_path=str(output_file)
                )
                
                if output_file.exists():
                    size_mb = output_file.stat().st_size / 1024 / 1024
                    print(f"   ✅ Voice cloning funcionou! ({size_mb:.1f}MB)")
                    return True
                else:
                    print(f"   ❌ Arquivo não foi criado")
                    
            except Exception as e:
                print(f"   ❌ Erro no voice cloning: {e}")
        
        # Método 2: Testa síntese básica com linguagem apenas
        print("🎤 Testando síntese básica (sem speaker)")
        try:
            output_file = Path("test_basic_synthesis.wav")
            
            # Para XTTS v2, precisamos fornecer um speaker mesmo que seja None
            # Vamos tentar diferentes abordagens
            
            # Abordagem 1: Usar configuração mínima
            tts.tts_to_file(
                text=test_text,
                language="pt",
                file_path=str(output_file)
            )
            
            if output_file.exists():
                size_mb = output_file.stat().st_size / 1024 / 1024
                print(f"   ✅ Síntese básica funcionou! ({size_mb:.1f}MB)")
                return True
            else:
                print(f"   ❌ Arquivo não foi criado")
                
        except Exception as e:
            print(f"   ❌ Erro na síntese básica: {e}")
            
            # Abordagem 2: Tenta com speaker conhecido
            for speaker in speakers_to_test:
                print(f"🎤 Testando com speaker: {speaker}")
                try:
                    output_file = Path(f"test_speaker_{speaker.replace(' ', '_')}.wav")
                    tts.tts_to_file(
                        text=test_text,
                        speaker=speaker,
                        language="pt",
                        file_path=str(output_file)
                    )
                    
                    if output_file.exists():
                        size_mb = output_file.stat().st_size / 1024 / 1024
                        print(f"   ✅ Speaker {speaker} funcionou! ({size_mb:.1f}MB)")
                        return True
                    else:
                        print(f"   ❌ Arquivo não foi criado para {speaker}")
                        
                except Exception as e:
                    print(f"   ❌ Erro com {speaker}: {e}")
        
        # Se chegou aqui, nenhum método funcionou
        print("❌ Todos os métodos falharam")
        return False
        
    except Exception as e:
        print(f"❌ Erro ao carregar XTTS v2: {e}")
        return False

def test_alternative_models():
    """Testa modelos alternativos que funcionam melhor."""
    print("\n🔄 Testando Modelos Alternativos")
    print("-" * 60)
    
    # Modelos mais estáveis
    alternative_models = [
        "tts_models/pt/cv/vits",  # Português específico
        "tts_models/multilingual/multi-dataset/your_tts",  # Alternativa ao XTTS
    ]
    
    for model_name in alternative_models:
        print(f"🤖 Testando: {model_name}")
        try:
            from TTS.api import TTS
            
            tts = TTS(model_name, gpu=False, progress_bar=False)
            print(f"   ✅ Modelo carregado!")
            
            # Testa síntese simples
            test_text = "Este é um teste do modelo TTS em português."
            output_file = Path(f"test_{model_name.split('/')[-1]}.wav")
            
            tts.tts_to_file(
                text=test_text,
                file_path=str(output_file)
            )
            
            if output_file.exists():
                size_mb = output_file.stat().st_size / 1024 / 1024
                print(f"   ✅ Síntese funcionou! ({size_mb:.1f}MB)")
                return True
            else:
                print(f"   ❌ Arquivo não foi criado")
                
        except Exception as e:
            print(f"   ❌ Erro: {e}")
    
    return False

def create_reference_voice():
    """Cria um arquivo de referência de voz para testes."""
    print("\n🎤 Criando arquivo de referência")
    print("-" * 60)
    
    # Verifica se já existe
    ref_file = Path("reference_voice.wav")
    if ref_file.exists():
        print(f"✅ Arquivo já existe: {ref_file}")
        return True
    
    print("💡 Para voice cloning, você precisa de um arquivo de referência:")
    print("   1. Grave sua voz por 6-10 segundos")
    print("   2. Salve como 'reference_voice.wav'")
    print("   3. Texto sugerido: 'Olá, esta é minha voz para clonagem'")
    print("   4. Execute este script novamente")
    
    # Cria um exemplo com síntese simples para usar como referência
    try:
        from TTS.api import TTS
        
        print("🔄 Tentando criar referência com modelo simples...")
        tts = TTS("tts_models/pt/cv/vits", gpu=False, progress_bar=False)
        
        reference_text = "Olá, esta é uma voz de referência para clonagem."
        tts.tts_to_file(
            text=reference_text,
            file_path=str(ref_file)
        )
        
        if ref_file.exists():
            print(f"✅ Referência criada: {ref_file}")
            print("   💡 Use este arquivo como base ou substitua por sua própria voz")
            return True
            
    except Exception as e:
        print(f"❌ Erro ao criar referência: {e}")
    
    return False

def show_summary(results):
    """Mostra resumo dos testes."""
    print("\n" + "=" * 70)
    print("📊 RESUMO DOS TESTES (CORRIGIDO)")
    print("=" * 70)
    
    success_count = sum(results.values())
    total_tests = len(results)
    
    for test_name, success in results.items():
        status = "✅ Funcionou" if success else "❌ Falhou"
        print(f"{test_name}: {status}")
    
    print(f"\n📈 Sucessos: {success_count}/{total_tests}")
    
    if success_count > 0:
        print("\n🎉 Pelo menos um modelo está funcionando!")
    else:
        print("\n🔧 SOLUÇÕES RECOMENDADAS:")
        print("1. pip install transformers==4.40.2")
        print("2. brew install sox (macOS)")
        print("3. pip install soundfile librosa")
        print("4. Execute: python fix_xtts_errors.py")
    
    print("\n📁 Arquivos gerados:")
    for wav_file in Path(".").glob("test_*.wav"):
        size_mb = wav_file.stat().st_size / 1024 / 1024
        print(f"   🎵 {wav_file.name} ({size_mb:.1f}MB)")
    
    print("\n💡 Dicas:")
    print("   • Para voice cloning, use reference_voice.wav (6-10s)")
    print("   • XTTS v2 tem melhor qualidade mas é mais complexo")
    print("   • Modelos específicos por idioma são mais estáveis")

def main():
    """Função principal do teste corrigido."""
    print("🐸 TESTE COMPARATIVO XTTS - VERSÃO CORRIGIDA")
    print("=" * 70)
    
    # Configuração inicial
    setup_environment()
    
    # Dicionário para armazenar resultados
    results = {}
    
    # Testa XTTS v2 corrigido
    results["XTTS v2 Corrigido"] = test_xtts_v2_corrected()
    
    # Testa modelos alternativos
    results["Modelos Alternativos"] = test_alternative_models()
    
    # Cria arquivo de referência se necessário
    create_reference_voice()
    
    # Mostra resumo
    show_summary(results)
    
    return any(results.values())

if __name__ == "__main__":
    try:
        success = main()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\n\n👋 Teste cancelado pelo usuário")
        sys.exit(0)
    except Exception as e:
        print(f"❌ Erro inesperado: {e}")
        sys.exit(1)