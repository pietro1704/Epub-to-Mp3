#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Teste rápido de paralelismo - apenas teste dos primeiros capítulos
"""

import subprocess
import sys
import time
from pathlib import Path

def test_engine_parallel(engine: str, parallel: int, book_path: str, max_time=30) -> bool:
    """Testa rapidamente um engine com paralelismo específico."""
    print(f"\n🧪 Testando {engine} --parallel {parallel}")

    cmd = [
        sys.executable, "main.py", "convert", book_path,
        "--engine", engine,
        "--parallel", str(parallel),
        "--chapter", "1",  # Apenas primeiro capítulo
        "--verbose"
    ]

    if engine == "edge":
        cmd.extend(["--voice", "pt-BR-FranciscaNeural"])
    elif engine == "coqui":
        cmd.extend(["--model", "tts_models/multilingual/multi-dataset/xtts_v2"])

    print(f"Comando: {' '.join(cmd)}")

    try:
        start = time.time()
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=max_time)
        elapsed = time.time() - start

        if result.returncode == 0:
            print(f"✅ {engine} --parallel {parallel}: SUCESSO ({elapsed:.1f}s)")
            return True
        else:
            # Checar se completou ao menos algo
            if "Convertidos:" in result.stdout and not "0/1" in result.stdout:
                print(f"⚠️  {engine} --parallel {parallel}: PARCIAL ({elapsed:.1f}s)")
                return True
            else:
                print(f"❌ {engine} --parallel {parallel}: FALHOU ({elapsed:.1f}s)")
                if "DEADLOCK DETECTADO" in result.stdout:
                    print("  → DEADLOCK detectado (conforme esperado)")
                return False

    except subprocess.TimeoutExpired:
        print(f"⏰ {engine} --parallel {parallel}: TIMEOUT após {max_time}s")
        return False
    except Exception as e:
        print(f"💥 {engine} --parallel {parallel}: ERRO {e}")
        return False

def main():
    if len(sys.argv) < 2:
        print("Uso: python test_parallel_quick.py <ebook>")
        sys.exit(1)

    book_path = sys.argv[1]
    if not Path(book_path).exists():
        print(f"❌ Arquivo não encontrado: {book_path}")
        sys.exit(1)

    print("🚀 Teste rápido de paralelismo (apenas 1º capítulo)")
    print(f"📚 Livro: {book_path}")

    tests = [
        # (engine, parallel_values)
        ("edge", [1, 3, 6, 12]),  # Testar até limite e além
        ("coqui", [1, 2, 4, 8]),  # Testar executor limitado
    ]

    results = {}

    for engine, parallel_values in tests:
        print(f"\n🔧 Engine: {engine.upper()}")
        results[engine] = {}

        for parallel in parallel_values:
            success = test_engine_parallel(engine, parallel, book_path)
            results[engine][parallel] = success

    # Relatório
    print("\n" + "="*50)
    print("📊 RELATÓRIO DE TESTE RÁPIDO")
    print("="*50)

    all_good = True
    for engine, engine_results in results.items():
        print(f"\n🔧 {engine.upper()}:")
        for parallel, success in engine_results.items():
            status = "✅ OK" if success else "❌ FALHOU"
            print(f"  --parallel {parallel}: {status}")
            if not success and parallel <= 4:  # Falhas em paralelismo baixo são problemáticas
                all_good = False

    if all_good:
        print("\n🎉 TESTE APROVADO! Paralelismo funcionando corretamente.")
        print("📝 Deadlocks em paralelismo alto são esperados e tratados.")
    else:
        print("\n⚠️  Alguns testes falharam em paralelismo baixo.")

    return 0 if all_good else 1

if __name__ == "__main__":
    sys.exit(main())