#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script de teste para validar as correções de paralelismo.
Testa diferentes configurações de --parallel para verificar se não trava mais.
"""

import subprocess
import time
import sys
from pathlib import Path

def test_parallel_config(engine: str, parallel: int, book_path: str) -> bool:
    """Testa uma configuração específica de paralelismo."""
    print(f"\n🧪 Testando {engine} com --parallel {parallel}")

    cmd = [
        sys.executable, "main.py", book_path,
        "--engine", engine,
        "--parallel", str(parallel),
        "--no-cache",  # Forçar reprocessamento
        "--verbose"    # Para debug
    ]

    if engine == "edge":
        cmd.extend(["--voice", "pt-BR-FranciscaNeural"])
    elif engine == "coqui":
        cmd.extend(["--coqui-model", "tts_models/multilingual/multi-dataset/xtts_v2"])
    elif engine == "piper":
        # Assumindo que existe um modelo piper
        model_path = Path("./models/pt_BR-faber-medium.onnx")
        if model_path.exists():
            cmd.extend(["--model-path", str(model_path)])
        else:
            print(f"⚠️  Modelo Piper não encontrado: {model_path}")
            return False

    print(f"Comando: {' '.join(cmd)}")

    try:
        # Timeout de 2 minutos para detectar travamentos
        start_time = time.time()
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True
        )

        # Monitorar saída em tempo real
        output_lines = []
        while True:
            line = process.stdout.readline()
            if line:
                print(f"  {line.rstrip()}")
                output_lines.append(line)

                # Detectar sinais de travamento
                if "DEADLOCK DETECTADO" in line:
                    print("❌ DEADLOCK detectado!")
                    process.terminate()
                    return False

                # Detectar conclusão
                if "✅" in line and "completo" in line:
                    print("✅ Conversão concluída com sucesso!")
                    break
            else:
                # Processo terminou
                break

            # Timeout de segurança
            if time.time() - start_time > 120:  # 2 minutos
                print("⏰ Timeout - processo travado!")
                process.terminate()
                return False

        # Aguardar finalização
        return_code = process.wait(timeout=10)

        if return_code == 0:
            print(f"✅ {engine} com --parallel {parallel}: SUCESSO")
            return True
        else:
            print(f"❌ {engine} com --parallel {parallel}: FALHOU (código {return_code})")
            return False

    except subprocess.TimeoutExpired:
        print(f"⏰ {engine} com --parallel {parallel}: TIMEOUT")
        process.kill()
        return False
    except Exception as e:
        print(f"💥 {engine} com --parallel {parallel}: ERRO {e}")
        return False

def main():
    if len(sys.argv) < 2:
        print("Uso: python test_parallel_fix.py <caminho_do_ebook>")
        print("Exemplo: python test_parallel_fix.py livro.epub")
        sys.exit(1)

    book_path = sys.argv[1]
    if not Path(book_path).exists():
        print(f"❌ Arquivo não encontrado: {book_path}")
        sys.exit(1)

    print("🚀 Iniciando testes de paralelismo...")
    print(f"📚 Livro: {book_path}")

    # Configurações de teste
    test_configs = [
        # (engine, parallel_values)
        ("edge", [1, 2, 4, 6, 8]),  # Testar até os limites antigos
        ("coqui", [1, 2, 4, 6]),    # Testar executors limitados
        ("piper", [1, 2, 4, 8, 12]) # Testar subprocess limits
    ]

    results = {}

    for engine, parallel_values in test_configs:
        print(f"\n🔧 Testando engine: {engine}")
        results[engine] = {}

        for parallel in parallel_values:
            success = test_parallel_config(engine, parallel, book_path)
            results[engine][parallel] = success

    # Relatório final
    print("\n" + "="*60)
    print("📊 RELATÓRIO FINAL DOS TESTES")
    print("="*60)

    all_passed = True
    for engine, engine_results in results.items():
        print(f"\n🔧 {engine.upper()}:")
        for parallel, success in engine_results.items():
            status = "✅ PASSOU" if success else "❌ FALHOU"
            print(f"  --parallel {parallel}: {status}")
            if not success:
                all_passed = False

    if all_passed:
        print("\n🎉 TODOS OS TESTES PASSARAM! O paralelismo foi corrigido.")
    else:
        print("\n⚠️  Alguns testes falharam. Verifique os logs acima.")

    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())