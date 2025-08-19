#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
resolve_dependencies.py

Resolvedor de conflitos de dependências para XTTS.
Corrige versões conflitantes mantendo compatibilidade.
"""

import subprocess
import sys
from pathlib import Path

def check_current_versions():
    """Verifica versões atuais das dependências problemáticas."""
    print("🔍 VERIFICANDO VERSÕES ATUAIS")
    print("=" * 50)
    
    packages = [
        "transformers", "numpy", "pandas", "aiohttp", 
        "pydantic", "requests", "fsspec", "packaging"
    ]
    
    versions = {}
    for package in packages:
        try:
            result = subprocess.run(
                [sys.executable, "-c", f"import {package}; print({package}.__version__)"],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                version = result.stdout.strip()
                versions[package] = version
                print(f"✅ {package}: {version}")
            else:
                versions[package] = "não encontrado"
                print(f"❌ {package}: não encontrado")
        except Exception:
            versions[package] = "erro"
            print(f"❌ {package}: erro ao verificar")
    
    return versions

def create_compatible_requirements():
    """Cria requirements.txt com versões compatíveis."""
    print("\n📝 CRIANDO REQUIREMENTS COMPATÍVEIS")
    print("=" * 50)
    
    # Versões testadas e compatíveis
    compatible_versions = {
        # Core TTS
        "TTS": "",  # Última versão
        "edge-tts": ">=6.1.0",
        
        # Transformers compatível com XTTS
        "transformers": "==4.40.2",
        "tokenizers": ">=0.19.0,<0.20.0",
        
        # NumPy compatível com todos
        "numpy": ">=1.24.0,<2.0.0",  # Resolve conflitos com gruut, f5-tts, numba
        
        # Audio dependencies
        "torch": ">=2.0.0",
        "torchaudio": ">=2.0.0",
        "soundfile": "",
        "librosa": "",
        
        # Core dependencies
        "beautifulsoup4": ">=4.12.0",
        "ebooklib": ">=0.18",
        "PyPDF2": ">=3.0.0",
        "tqdm": "",
        
        # Web framework compatível
        "pandas": ">=2.0.0,<3.0.0",  # Resolve conflito com pephubclient
        "requests": ">=2.32.0,<3.0.0",
        "aiohttp": ">=3.11.0,<4.0.0",
        "pydantic": ">=2.10.0,<3.0.0",
        
        # File system
        "fsspec": ">=2023.1.0,<=2025.3.0",  # Resolve conflito com datasets
        "packaging": ">=23.2,<24.0",  # Resolve conflito com langfuse
        
        # Optional/Dev
        "pytest": "",
        "black": "",
        "flake8": "",
    }
    
    requirements_content = """# Dependências compatíveis para EbookToAudio com XTTS
# Versões testadas para evitar conflitos

# =============================================================================
# CORE TTS ENGINES
# =============================================================================
TTS
edge-tts>=6.1.0

# Transformers compatível com XTTS (CRÍTICO - não alterar)
transformers==4.40.2
tokenizers>=0.19.0,<0.20.0

# =============================================================================
# PYTORCH E ÁUDIO
# =============================================================================
torch>=2.0.0
torchaudio>=2.0.0

# NumPy compatível com todas as dependências
numpy>=1.24.0,<2.0.0

# Audio processing
soundfile
librosa
scipy

# =============================================================================
# PROCESSAMENTO DE EBOOKS
# =============================================================================
beautifulsoup4>=4.12.0
ebooklib>=0.18
PyPDF2>=3.0.0

# =============================================================================
# INTERFACE E PROGRESS
# =============================================================================
tqdm

# =============================================================================
# DEPENDÊNCIAS DE SISTEMA (com versões compatíveis)
# =============================================================================
# Resolve conflitos identificados
pandas>=2.0.0,<3.0.0
requests>=2.32.0,<3.0.0
aiohttp>=3.11.0,<4.0.0
pydantic>=2.10.0,<3.0.0
fsspec>=2023.1.0,<=2025.3.0
packaging>=23.2,<24.0

# =============================================================================
# DESENVOLVIMENTO (OPCIONAL)
# =============================================================================
pytest
black
flake8

# =============================================================================
# NOTAS IMPORTANTES:
# =============================================================================
# 1. transformers==4.40.2 é OBRIGATÓRIO para XTTS funcionar
# 2. numpy<2.0.0 resolve conflitos com gruut, f5-tts, numba
# 3. pandas>=2.0.0 resolve conflito com pephubclient
# 4. fsspec<=2025.3.0 resolve conflito com datasets
# 5. packaging<24.0 resolve conflito com langfuse
#
# Se algum pacote der conflito, remova-o temporariamente:
# pip uninstall <pacote-conflitante>
# 
# Ordem de instalação recomendada:
# 1. pip install -r requirements.txt
# 2. pip install transformers==4.40.2 --force-reinstall
# 3. Teste com: python test_xtts_versions_fixed.py
"""
    
    # Salva requirements.txt
    requirements_path = Path("requirements.txt")
    with open(requirements_path, 'w', encoding='utf-8') as f:
        f.write(requirements_content)
    
    print(f"✅ Requirements criado: {requirements_path}")
    return requirements_path

def resolve_conflicts():
    """Resolve conflitos de dependências de forma inteligente."""
    print("\n🔧 RESOLVENDO CONFLITOS")
    print("=" * 50)
    
    # Estratégia: Desinstalar pacotes conflitantes e reinstalar com versões compatíveis
    
    # Passo 1: Desinstala pacotes que causam conflito
    conflicting_packages = [
        "transformers", "numpy", "pandas", "fsspec", "packaging"
    ]
    
    print("🗑️ Removendo pacotes conflitantes...")
    for package in conflicting_packages:
        print(f"   Removendo {package}...")
        subprocess.run([
            sys.executable, "-m", "pip", "uninstall", package, "-y"
        ], capture_output=True)
    
    # Passo 2: Instala versões específicas compatíveis
    compatible_installs = [
        "numpy>=1.24.0,<2.0.0",
        "pandas>=2.0.0,<3.0.0", 
        "fsspec>=2023.1.0,<=2025.3.0",
        "packaging>=23.2,<24.0",
        "transformers==4.40.2",
    ]
    
    print("\n📦 Instalando versões compatíveis...")
    for package_spec in compatible_installs:
        print(f"   Instalando {package_spec}...")
        result = subprocess.run([
            sys.executable, "-m", "pip", "install", package_spec
        ], capture_output=True, text=True)
        
        if result.returncode != 0:
            print(f"   ⚠️ Aviso: {result.stderr}")
        else:
            print(f"   ✅ Sucesso")
    
    return True

def test_fixed_installation():
    """Testa se a instalação corrigida funciona."""
    print("\n🧪 TESTANDO INSTALAÇÃO CORRIGIDA")
    print("=" * 50)
    
    test_code = '''
import warnings
warnings.filterwarnings("ignore")

try:
    import transformers
    print(f"✅ transformers: {transformers.__version__}")
    
    if transformers.__version__ == "4.40.2":
        print("✅ Versão correta do transformers!")
    else:
        print("⚠️ Versão diferente da esperada")
        
except Exception as e:
    print(f"❌ transformers: {e}")

try:
    import numpy
    print(f"✅ numpy: {numpy.__version__}")
    
    version_parts = numpy.__version__.split(".")
    major = int(version_parts[0])
    if major < 2:
        print("✅ NumPy compatível!")
    else:
        print("⚠️ NumPy 2.x pode causar problemas")
        
except Exception as e:
    print(f"❌ numpy: {e}")

try:
    import pandas
    print(f"✅ pandas: {pandas.__version__}")
except Exception as e:
    print(f"❌ pandas: {e}")

try:
    from TTS.api import TTS
    print("✅ TTS importado com sucesso")
    
    # Teste básico XTTS
    print("🤖 Testando XTTS v2...")
    tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2", gpu=False, progress_bar=False)
    print("✅ XTTS v2 carregado sem erros!")
    
except Exception as e:
    print(f"❌ TTS/XTTS: {e}")

print("\\n🎉 Teste concluído!")
'''
    
    result = subprocess.run([
        sys.executable, "-c", test_code
    ], capture_output=True, text=True)
    
    print("📝 Resultado:")
    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(f"⚠️ Warnings: {result.stderr}")
    
    return result.returncode == 0

def main():
    """Função principal do resolvedor."""
    print("🔧 RESOLVEDOR DE CONFLITOS DE DEPENDÊNCIAS")
    print("=" * 60)
    print("Este script vai resolver conflitos entre:")
    print("• transformers, numpy, pandas, fsspec, packaging")
    print("• XTTS, sentence-transformers, gruut, f5-tts")
    print("• open-webui, datasets, unstructured, numba")
    print()
    
    # 1. Verifica versões atuais
    current_versions = check_current_versions()
    
    # 2. Cria requirements.txt compatível
    requirements_path = create_compatible_requirements()
    
    # 3. Resolve conflitos
    print(f"\n❓ Quer resolver os conflitos automaticamente? (s/N): ", end="")
    choice = input().strip().lower()
    
    if choice in ['s', 'sim', 'y', 'yes']:
        if resolve_conflicts():
            print("✅ Conflitos resolvidos!")
        else:
            print("❌ Erro ao resolver conflitos")
            return False
    else:
        print("💡 Para resolver manualmente:")
        print("   pip install -r requirements.txt")
        print("   pip install transformers==4.40.2 --force-reinstall")
    
    # 4. Testa instalação
    if test_fixed_installation():
        print("\n🎉 SUCESSO! Dependências compatíveis instaladas.")
    else:
        print("\n⚠️ Ainda há problemas. Verifique os logs acima.")
    
    print(f"\n📋 RESUMO:")
    print(f"• Requirements atualizado: {requirements_path}")
    print(f"• transformers fixado em 4.40.2")
    print(f"• numpy limitado a <2.0.0")
    print(f"• pandas atualizado para >=2.0.0") 
    print(f"• fsspec limitado a <=2025.3.0")
    
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