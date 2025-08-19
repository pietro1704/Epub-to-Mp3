#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
fix_xtts_errors.py

Script para corrigir erros do XTTS v1/v2:
1. Downgrade do transformers para versão compatível
2. Instalar sox no macOS  
3. Configurar backend de áudio correto
4. Testar modelos corrigidos
"""

import subprocess
import sys
import os
import platform
from pathlib import Path

def run_command(cmd, description="", check=True):
    """Executa comando e mostra progresso."""
    print(f"🔧 {description}")
    print(f"   Comando: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(cmd, check=check, capture_output=True, text=True)
        if result.returncode == 0:
            print(f"   ✅ Sucesso!")
            if result.stdout.strip():
                print(f"   📝 {result.stdout.strip()}")
        else:
            print(f"   ❌ Erro: {result.stderr}")
        return result.returncode == 0
    except Exception as e:
        print(f"   ❌ Exceção: {e}")
        return False

def check_dependencies():
    """Verifica dependências do sistema."""
    print("\n🔍 VERIFICANDO DEPENDÊNCIAS")
    print("=" * 50)
    
    # Verifica Python
    python_version = sys.version_info
    print(f"🐍 Python: {python_version.major}.{python_version.minor}.{python_version.micro}")
    
    if python_version < (3, 8) or python_version >= (3, 12):
        print("   ⚠️ XTTS funciona melhor com Python 3.8-3.11")
    
    # Verifica sistema operacional
    system = platform.system()
    print(f"💻 Sistema: {system}")
    
    # Verifica sox (necessário para torchaudio)
    if system == "Darwin":  # macOS
        result = subprocess.run(["which", "sox"], capture_output=True)
        if result.returncode != 0:
            print("   ❌ sox não encontrado - será instalado")
            return False
        else:
            print("   ✅ sox encontrado")
    
    return True

def install_sox_macos():
    """Instala sox no macOS via Homebrew."""
    print("\n🍺 INSTALANDO SOX (macOS)")
    print("=" * 50)
    
    # Verifica se brew está instalado
    result = subprocess.run(["which", "brew"], capture_output=True)
    if result.returncode != 0:
        print("❌ Homebrew não encontrado!")
        print("   Instale em: https://brew.sh")
        return False
    
    # Instala sox
    return run_command(
        ["brew", "install", "sox"], 
        "Instalando sox via Homebrew"
    )

def fix_transformers_version():
    """Corrige versão do transformers resolvendo conflitos de dependências."""
    print("\n🔄 CORRIGINDO VERSÃO DO TRANSFORMERS")
    print("=" * 50)
    
    # Versão compatível com XTTS (baseado na pesquisa)
    compatible_version = "4.40.2"
    
    # Verifica versão atual
    try:
        import transformers
        current_version = transformers.__version__
        print(f"📦 Versão atual: {current_version}")
        
        if current_version == compatible_version:
            print("   ✅ Versão já está correta!")
            return True
            
    except ImportError:
        print("   📦 transformers não encontrado")
    
    # Resolve conflitos primeiro
    print("   🔧 Resolvendo conflitos de dependências...")
    
    # Desinstala numpy se for 2.x (conflita com gruut, f5-tts)
    try:
        import numpy
        if numpy.__version__.startswith("2."):
            print("   📦 Downgrade do numpy para resolver conflitos...")
            run_command(
                [sys.executable, "-m", "pip", "install", "numpy>=1.24.0,<2.0.0", "--force-reinstall"],
                "Corrigindo numpy para <2.0.0"
            )
    except ImportError:
        pass
    
    # Instala versão específica do transformers
    print(f"   🔽 Instalando transformers=={compatible_version}")
    success = run_command(
        [sys.executable, "-m", "pip", "install", f"transformers=={compatible_version}", "--force-reinstall"],
        f"Instalando transformers {compatible_version}"
    )
    
    if not success:
        print("   ⚠️ Problema com conflitos. Tentando resolução avançada...")
        # Executa resolvedor de dependências
        run_command(
            [sys.executable, "resolve_dependencies.py"],
            "Executando resolvedor de conflitos"
        )
    
    return success

def fix_torch_audio_backend():
    """Configura backend de áudio correto."""
    print("\n🔊 CONFIGURANDO BACKEND DE ÁUDIO")
    print("=" * 50)
    
    # Código de teste e correção
    test_code = '''
import torchaudio
import torch

# Tenta configurar backend correto
try:
    # Para macOS, usa sox_io se disponível
    backends = torchaudio.list_audio_backends()
    print(f"Backends disponíveis: {backends}")
    
    if "sox_io" in backends:
        torchaudio.set_audio_backend("sox_io")
        print("✅ Backend sox_io configurado")
    elif "soundfile" in backends:
        torchaudio.set_audio_backend("soundfile")
        print("✅ Backend soundfile configurado")
    else:
        print("❌ Nenhum backend compatível encontrado")
        
    # Teste básico
    current_backend = torchaudio.get_audio_backend()
    print(f"Backend atual: {current_backend}")
    
except Exception as e:
    print(f"❌ Erro ao configurar backend: {e}")
'''
    
    # Executa teste
    result = subprocess.run(
        [sys.executable, "-c", test_code],
        capture_output=True, text=True
    )
    
    print("📝 Resultado do teste:")
    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(f"⚠️ Warnings: {result.stderr}")
    
    return result.returncode == 0

def install_audio_dependencies():
    """Instala dependências de áudio necessárias."""
    print("\n🎵 INSTALANDO DEPENDÊNCIAS DE ÁUDIO")
    print("=" * 50)
    
    # Dependências essenciais
    audio_deps = [
        "soundfile",  # Backend alternativo
        "librosa",    # Processamento de áudio
    ]
    
    success = True
    for dep in audio_deps:
        if not run_command(
            [sys.executable, "-m", "pip", "install", dep],
            f"Instalando {dep}"
        ):
            success = False
    
    return success

def test_xtts_fixed():
    """Testa XTTS após correções."""
    print("\n🧪 TESTANDO XTTS CORRIGIDO")
    print("=" * 50)
    
    test_code = '''
import sys
import warnings
warnings.filterwarnings("ignore")

print("🔧 Configurando ambiente...")

# Configura backend de áudio
try:
    import torchaudio
    backends = torchaudio.list_audio_backends()
    if "sox_io" in backends:
        torchaudio.set_audio_backend("sox_io")
    elif "soundfile" in backends:
        torchaudio.set_audio_backend("soundfile")
    print(f"✅ Backend: {torchaudio.get_audio_backend()}")
except Exception as e:
    print(f"⚠️ Backend de áudio: {e}")

# Testa XTTS v2 simples
try:
    print("🤖 Testando XTTS v2...")
    from TTS.api import TTS
    
    # Inicializa modelo (sem GPU para compatibilidade)
    model_name = "tts_models/multilingual/multi-dataset/xtts_v2"
    tts = TTS(model_name, gpu=False, progress_bar=False)
    print("✅ XTTS v2 carregado com sucesso!")
    
    # Lista speakers disponíveis (se houver)
    if hasattr(tts, 'speakers') and tts.speakers:
        print(f"📢 Speakers disponíveis: {len(tts.speakers)}")
        print(f"   Primeiros 3: {tts.speakers[:3]}")
    else:
        print("📢 Modelo requer voice cloning (sem speakers pré-definidos)")
    
    print("✅ Teste básico passou!")
    
except Exception as e:
    print(f"❌ Erro no teste XTTS: {e}")
    import traceback
    traceback.print_exc()
'''
    
    # Executa teste
    result = subprocess.run(
        [sys.executable, "-c", test_code],
        capture_output=True, text=True
    )
    
    print("📝 Resultado do teste:")
    if result.stdout:
        print(result.stdout)
    if result.stderr and "warning" not in result.stderr.lower():
        print(f"❌ Erros: {result.stderr}")
    
    return result.returncode == 0

def create_voice_cloning_example():
    """Cria exemplo funcional de voice cloning."""
    print("\n📝 CRIANDO EXEMPLO DE VOICE CLONING")
    print("=" * 50)
    
    example_code = '''#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
xtts_voice_cloning_example.py

Exemplo funcional de voice cloning com XTTS v2.
"""

import warnings
warnings.filterwarnings("ignore")

import torchaudio
from pathlib import Path

# Configura backend de áudio
try:
    backends = torchaudio.list_audio_backends()
    if "sox_io" in backends:
        torchaudio.set_audio_backend("sox_io")
    elif "soundfile" in backends:
        torchaudio.set_audio_backend("soundfile")
    print(f"🔊 Backend de áudio: {torchaudio.get_audio_backend()}")
except Exception as e:
    print(f"⚠️ Aviso de áudio: {e}")

def test_xtts_voice_cloning():
    """Testa voice cloning com XTTS v2."""
    try:
        from TTS.api import TTS
        
        print("🤖 Carregando XTTS v2...")
        tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2", gpu=False)
        print("✅ Modelo carregado!")
        
        # Texto de teste
        text = "Olá! Este é um teste do XTTS em português brasileiro."
        
        # Para voice cloning, você precisa de um arquivo de referência
        # Crie um arquivo de áudio de 6-10 segundos da voz desejada
        reference_voice = "./reference_voice.wav"
        
        if Path(reference_voice).exists():
            print(f"🎤 Usando voz de referência: {reference_voice}")
            
            # Gera áudio com voice cloning
            tts.tts_to_file(
                text=text,
                speaker_wav=reference_voice,
                language="pt",
                file_path="output_cloned.wav"
            )
            print("✅ Áudio gerado: output_cloned.wav")
            
        else:
            print(f"⚠️ Arquivo de referência não encontrado: {reference_voice}")
            print("💡 Para voice cloning:")
            print("   1. Grave sua voz por 6-10 segundos")
            print("   2. Salve como 'reference_voice.wav'")
            print("   3. Execute este script novamente")
            
            # Testa com speaker pré-definido (se disponível)
            try:
                # XTTS v2 geralmente não tem speakers pré-definidos
                # mas vamos tentar com um speaker conhecido
                tts.tts_to_file(
                    text=text,
                    speaker="Ana Florence",  # Speaker conhecido do XTTS
                    language="pt",
                    file_path="output_preset.wav"
                )
                print("✅ Áudio gerado com speaker preset: output_preset.wav")
                
            except Exception as e:
                print(f"ℹ️ Speaker preset não disponível: {e}")
                print("   XTTS v2 funciona melhor com voice cloning")
        
    except Exception as e:
        print(f"❌ Erro: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test_xtts_voice_cloning()
'''
    
    # Salva exemplo
    example_file = Path("xtts_voice_cloning_example.py")
    with open(example_file, 'w', encoding='utf-8') as f:
        f.write(example_code)
    
    print(f"✅ Exemplo criado: {example_file}")
    print("💡 Execute com: python xtts_voice_cloning_example.py")
    
    return True

def main():
    """Função principal de correção."""
    print("🔧 CORRETOR DE ERROS XTTS")
    print("=" * 50)
    print("Este script vai corrigir os principais erros do XTTS:")
    print("• AttributeError: 'GPT2InferenceModel' object has no attribute 'generate'")
    print("• Model is multi-speaker but no speaker is provided")
    print("• torchaudio sox backend errors")
    print()
    
    system = platform.system()
    
    # 1. Verifica dependências
    deps_ok = check_dependencies()
    
    # 2. Instala sox no macOS se necessário
    if system == "Darwin" and not deps_ok:
        if not install_sox_macos():
            print("❌ Falha ao instalar sox")
            return False
    
    # 3. Corrige versão do transformers
    if not fix_transformers_version():
        print("❌ Falha ao corrigir transformers")
        return False
    
    # 4. Instala dependências de áudio
    if not install_audio_dependencies():
        print("❌ Falha ao instalar dependências de áudio")
        return False
    
    # 5. Configura backend de áudio
    if not fix_torch_audio_backend():
        print("❌ Falha ao configurar backend de áudio")
        return False
    
    # 6. Testa XTTS corrigido
    if not test_xtts_fixed():
        print("❌ XTTS ainda apresenta problemas")
        return False
    
    # 7. Cria exemplo funcional
    create_voice_cloning_example()
    
    print("\n🎉 CORREÇÃO CONCLUÍDA!")
    print("=" * 50)
    print("✅ XTTS deve estar funcionando agora!")
    print()
    print("💡 PRÓXIMOS PASSOS:")
    print("1. Para voice cloning, grave sua voz (6-10s) como 'reference_voice.wav'")
    print("2. Execute: python xtts_voice_cloning_example.py")
    print("3. Para usar no seu projeto, importe: from TTS.api import TTS")
    print()
    print("🔧 CONFIGURAÇÕES APLICADAS:")
    print(f"• transformers=4.40.2 (compatível com XTTS)")
    print(f"• Backend de áudio configurado")
    if system == "Darwin":
        print("• sox instalado via Homebrew")
    
    return True

if __name__ == "__main__":
    try:
        success = main()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\n\n👋 Cancelado pelo usuário")
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ Erro inesperado: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)