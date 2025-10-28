#!/usr/bin/env python3
"""
Script de teste para validar o sistema de paths centralizados.
Pode ser executado de qualquer diretório do projeto.
"""

import sys
from pathlib import Path

# Adiciona python_app ao path se necessário
project_root = Path(__file__).parent
python_app = project_root / "python_app"
if str(python_app) not in sys.path:
    sys.path.insert(0, str(python_app))

from src.paths import PROJECT_ROOT, CACHE_DIR, OUTPUT_DIR, get_cache_path, get_output_path
from src.config import AppConfig
from src.cache_manager import CacheManager

def test_paths():
    """Testa se os paths estão corretos"""
    print("=" * 60)
    print("🧪 Teste do Sistema de Paths Centralizados")
    print("=" * 60)
    print()

    print("📁 Paths Básicos:")
    print(f"  Project Root: {PROJECT_ROOT}")
    print(f"  Cache Dir:    {CACHE_DIR}")
    print(f"  Output Dir:   {OUTPUT_DIR}")
    print()

    print("✅ Validações:")
    assert PROJECT_ROOT.exists(), "❌ Project root não existe"
    print(f"  ✓ Project root existe: {PROJECT_ROOT.exists()}")

    assert CACHE_DIR.exists(), "❌ Cache dir não existe"
    print(f"  ✓ Cache dir existe: {CACHE_DIR.exists()}")

    assert OUTPUT_DIR.exists(), "❌ Output dir não existe"
    print(f"  ✓ Output dir existe: {OUTPUT_DIR.exists()}")

    assert CACHE_DIR.parent == PROJECT_ROOT, "❌ Cache não está na raiz"
    print(f"  ✓ Cache está na raiz do projeto")

    assert OUTPUT_DIR.parent == PROJECT_ROOT, "❌ Output não está na raiz"
    print(f"  ✓ Output está na raiz do projeto")
    print()

    print("🔧 Helpers:")
    test_cache = get_cache_path("test", "file.json")
    test_output = get_output_path("test", "audio.mp3")
    print(f"  get_cache_path('test', 'file.json'):  {test_cache}")
    print(f"  get_output_path('test', 'audio.mp3'): {test_output}")
    print()

    print("⚙️  Integração com AppConfig:")
    config = AppConfig().create_conversion_config('edge')
    print(f"  Config Output Dir: {config.output_dir}")
    print(f"  Config Cache Dir:  {config.cache_dir}")
    assert config.output_dir == OUTPUT_DIR, "❌ Config output dir incorreto"
    assert config.cache_dir == CACHE_DIR, "❌ Config cache dir incorreto"
    print(f"  ✓ Config usa paths corretos")
    print()

    print("💾 Integração com CacheManager:")
    cache_manager = CacheManager()
    print(f"  CacheManager dir: {cache_manager.cache_dir}")
    assert cache_manager.cache_dir == CACHE_DIR, "❌ CacheManager dir incorreto"
    print(f"  ✓ CacheManager usa path correto")
    print()

    print("=" * 60)
    print("✅ Todos os testes passaram!")
    print("=" * 60)
    print()
    print("📝 Resumo:")
    print(f"  • Cache e output sempre em: {PROJECT_ROOT}")
    print(f"  • Executando de: {Path.cwd()}")
    print(f"  • Os paths são os mesmos independente do diretório de execução!")
    print()

if __name__ == "__main__":
    try:
        test_paths()
    except AssertionError as e:
        print(f"\n❌ Erro: {e}\n")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Erro inesperado: {e}\n")
        import traceback
        traceback.print_exc()
        sys.exit(1)
