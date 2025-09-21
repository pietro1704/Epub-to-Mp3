#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Teste de performance: paralelismo vs sequencial
"""

import subprocess
import time
import sys
from pathlib import Path

def run_conversion_test(book_path: str, engine: str, parallel: int, chapter: str = "4") -> dict:
    """Executa um teste de conversão e mede o tempo."""
    print(f"\n🧪 Testando {engine} --parallel {parallel} (cap: {chapter})")

    cmd = [
        sys.executable, "main.py", "convert", book_path,
        "--engine", engine,
        "--parallel", str(parallel),
        "--chapter", chapter,
        "--clear-cache"  # Limpar cache para teste justo
    ]

    if engine == "edge":
        cmd.extend(["--voice", "pt-BR-FranciscaNeural"])

    print(f"Comando: {' '.join(cmd[-6:])}")  # Mostrar só parte relevante

    try:
        start_time = time.time()
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        end_time = time.time()

        duration = end_time - start_time
        success = result.returncode == 0

        # Extrair estatísticas do output
        output = result.stdout
        errors = result.stderr

        # Procurar por informações de conversão
        converted = 0
        total = 0
        if "Convertidos:" in output:
            line = [l for l in output.split('\n') if "Convertidos:" in l][0]
            # Formato: "✅ Convertidos: X/Y"
            if "/" in line:
                parts = line.split("/")
                converted = int(parts[0].split(":")[-1].strip())
                total = int(parts[1].strip())

        result_data = {
            "parallel": parallel,
            "duration": duration,
            "success": success,
            "converted": converted,
            "total": total,
            "throughput": converted / duration if duration > 0 else 0,
            "output": output,
            "errors": errors
        }

        status = "✅ SUCESSO" if success else "❌ FALHOU"
        print(f"  {status}: {duration:.1f}s, {converted}/{total} capítulos, {result_data['throughput']:.2f} cap/s")

        return result_data

    except subprocess.TimeoutExpired:
        print(f"  ⏰ TIMEOUT após 180s")
        return {
            "parallel": parallel,
            "duration": 180,
            "success": False,
            "converted": 0,
            "total": 0,
            "throughput": 0,
            "output": "",
            "errors": "timeout"
        }
    except Exception as e:
        print(f"  💥 ERRO: {e}")
        return {
            "parallel": parallel,
            "duration": 0,
            "success": False,
            "converted": 0,
            "total": 0,
            "throughput": 0,
            "output": "",
            "errors": str(e)
        }

def main():
    if len(sys.argv) < 2:
        print("Uso: python test_performance.py <ebook>")
        print("Exemplo: python test_performance.py livro.epub")
        sys.exit(1)

    book_path = sys.argv[1]
    if not Path(book_path).exists():
        print(f"❌ Arquivo não encontrado: {book_path}")
        sys.exit(1)

    print("🚀 Teste de Performance: Paralelismo vs Sequencial")
    print(f"📚 Livro: {book_path}")
    print("📝 Testando capítulo 4 para velocidade")

    # Configurações de teste
    engines = ["edge"]  # Focar no Edge que é mais rápido para teste
    parallel_configs = [1, 2, 4, 6]  # 1 = sequencial, outros = paralelo

    results = {}

    for engine in engines:
        print(f"\n🔧 Engine: {engine.upper()}")
        results[engine] = []

        for parallel in parallel_configs:
            result = run_conversion_test(book_path, engine, parallel, chapter="4")
            results[engine].append(result)

            # Pausa entre testes para não sobrecarregar
            time.sleep(2)

    # Análise dos resultados
    print("\n" + "="*60)
    print("📊 ANÁLISE DE PERFORMANCE")
    print("="*60)

    for engine, engine_results in results.items():
        print(f"\n🔧 {engine.upper()}:")

        # Encontrar melhor performance
        successful_results = [r for r in engine_results if r["success"]]
        if not successful_results:
            print("  ❌ Nenhum teste bem-sucedido")
            continue

        # Ordenar por throughput (capítulos por segundo)
        successful_results.sort(key=lambda x: x["throughput"], reverse=True)

        best = successful_results[0]
        sequential = [r for r in successful_results if r["parallel"] == 1]

        print("  📈 Resultados (ordenados por throughput):")
        for r in successful_results:
            parallel_label = "Sequencial" if r["parallel"] == 1 else f"Paralelo {r['parallel']}"
            print(f"    {parallel_label:>12}: {r['duration']:>5.1f}s | {r['throughput']:>5.2f} cap/s")

        print(f"\n  🏆 Melhor: {best['parallel']} workers ({best['throughput']:.2f} cap/s)")

        if sequential:
            seq_result = sequential[0]
            if best["parallel"] == 1:
                print("  📊 Sequencial é o mais rápido!")
            else:
                speedup = best["throughput"] / seq_result["throughput"]
                print(f"  📊 Speedup do paralelismo: {speedup:.2f}x")
                if speedup < 1.2:
                    print("  ⚠️  Paralelismo oferece pouco benefício (<20%)")

    # Recomendações
    print("\n🎯 RECOMENDAÇÕES:")

    for engine, engine_results in results.items():
        successful = [r for r in engine_results if r["success"]]
        if not successful:
            continue

        best = max(successful, key=lambda x: x["throughput"])
        sequential = [r for r in successful if r["parallel"] == 1]

        if sequential:
            seq = sequential[0]
            if best["parallel"] == 1:
                print(f"  {engine}: Use modo sequencial (--parallel 1)")
            else:
                speedup = best["throughput"] / seq["throughput"]
                if speedup > 1.5:
                    print(f"  {engine}: Use --parallel {best['parallel']} (speedup {speedup:.1f}x)")
                else:
                    print(f"  {engine}: Paralelismo pouco efetivo, considere --parallel 1")

if __name__ == "__main__":
    main()