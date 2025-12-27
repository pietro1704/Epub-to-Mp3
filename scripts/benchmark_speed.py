#!/usr/bin/env python3
"""
Benchmark script to compare TTS engine speeds with and without parallel processing.

Usage:
    python scripts/benchmark_speed.py <book.epub> [--chapters N]
"""

import argparse
import asyncio
import sys
import time
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent / "python_app"))

from src.ebook_reader import EbookReader
from src.tts.coqui_engine import CoquiTTSEngine
from src.tts.edge_engine import EdgeTTSEngine


async def benchmark_edge(text: str, mode: str) -> dict:
    """Benchmark Edge TTS with sequential or parallel mode."""
    import tempfile

    enable_parallel = mode == "parallel"
    engine = EdgeTTSEngine(
        voice="pt-BR-ThalitaMultilingualNeural",
        verbose=False,
        enable_parallel=enable_parallel,
    )

    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
        output_path = Path(tmp.name)

    start = time.time()
    result = await engine.synthesize_async(text, output_path)
    duration = time.time() - start

    file_size = output_path.stat().st_size if result and output_path.exists() else 0

    # Cleanup
    if output_path.exists():
        output_path.unlink()

    return {
        "engine": "Edge TTS",
        "mode": mode,
        "duration": duration,
        "chars": len(text),
        "chars_per_sec": len(text) / duration if duration > 0 else 0,
        "success": result is not None,
        "file_size": file_size,
    }


async def benchmark_coqui(text: str) -> dict:
    """Benchmark Coqui TTS (always parallel for multi-segment)."""
    import tempfile

    try:
        engine = CoquiTTSEngine(
            voice="tts_models/pt/cv/vits",
            verbose=False,
        )

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            output_path = Path(tmp.name)

        start = time.time()
        result = await engine.synthesize_async(text, output_path)
        duration = time.time() - start

        file_size = output_path.stat().st_size if result and output_path.exists() else 0

        # Cleanup
        if output_path.exists():
            output_path.unlink()

        return {
            "engine": "Coqui TTS",
            "mode": "parallel",
            "duration": duration,
            "chars": len(text),
            "chars_per_sec": len(text) / duration if duration > 0 else 0,
            "success": result is not None,
            "file_size": file_size,
        }
    except Exception as e:
        print(f"⚠️ Coqui TTS não disponível: {e}")
        return None


async def main():
    parser = argparse.ArgumentParser(description="Benchmark TTS engine speeds")
    parser.add_argument("input_file", help="EPUB file to test")
    parser.add_argument(
        "--chapters", type=int, default=3, help="Number of chapters to test (default: 3)"
    )
    parser.add_argument("--skip-coqui", action="store_true", help="Skip Coqui TTS benchmark")
    args = parser.parse_args()

    if not Path(args.input_file).exists():
        print(f"❌ Arquivo não encontrado: {args.input_file}")
        return 1

    print("=" * 80)
    print("🚀 BENCHMARK DE VELOCIDADE - TTS ENGINES")
    print("=" * 80)
    print()

    # Load book
    print(f"📖 Carregando livro: {Path(args.input_file).name}")
    reader = EbookReader(args.input_file)
    chapters = list(reader.get_chapters())

    if not chapters:
        print("❌ Nenhum capítulo encontrado")
        return 1

    # Get sample text from first N chapters
    sample_text = ""
    for i, chapter in enumerate(chapters[: args.chapters]):
        if i >= args.chapters:
            break
        sample_text += chapter.text + "\n\n"

    chars_total = len(sample_text)
    print(f"📊 Texto de teste: {args.chapters} capítulos, {chars_total:,} caracteres")
    print()

    # Run benchmarks
    results = []

    print("⏱️ Testando Edge TTS (modo sequencial)...")
    result_edge_seq = await benchmark_edge(sample_text, "sequential")
    results.append(result_edge_seq)
    print(
        f"   ✅ {result_edge_seq['duration']:.1f}s ({result_edge_seq['chars_per_sec']:.0f} chars/s)"
    )
    print()

    print("⏱️ Testando Edge TTS (modo paralelo)...")
    result_edge_par = await benchmark_edge(sample_text, "parallel")
    results.append(result_edge_par)
    print(
        f"   ✅ {result_edge_par['duration']:.1f}s ({result_edge_par['chars_per_sec']:.0f} chars/s)"
    )
    print()

    if not args.skip_coqui:
        print("⏱️ Testando Coqui TTS...")
        result_coqui = await benchmark_coqui(sample_text)
        if result_coqui:
            results.append(result_coqui)
            print(
                f"   ✅ {result_coqui['duration']:.1f}s ({result_coqui['chars_per_sec']:.0f} chars/s)"
            )
        print()

    # Display results
    print("=" * 80)
    print("📊 RESULTADOS DO BENCHMARK")
    print("=" * 80)
    print()

    print(f"{'Engine':<20} {'Modo':<15} {'Tempo':<10} {'Chars/s':<12} {'Speedup'}")
    print("-" * 80)

    baseline = result_edge_seq["duration"]
    for result in results:
        speedup = baseline / result["duration"] if result["duration"] > 0 else 0
        speedup_str = f"{speedup:.2f}x" if speedup != 1.0 else "baseline"

        print(
            f"{result['engine']:<20} {result['mode']:<15} {result['duration']:>7.1f}s  "
            f"{result['chars_per_sec']:>10.0f}  {speedup_str:>8}"
        )

    print()
    print("=" * 80)
    print("💡 RECOMENDAÇÕES")
    print("=" * 80)
    print()

    # Find fastest
    fastest = min(results, key=lambda x: x["duration"])
    improvement = (baseline - fastest["duration"]) / baseline * 100

    print(f"🏆 Engine mais rápido: {fastest['engine']} ({fastest['mode']})")
    print(f"⚡ Melhoria sobre baseline: {improvement:.1f}%")
    print()

    # Recommendations
    if fastest["engine"] == "Edge TTS" and fastest["mode"] == "parallel":
        print("✅ Recomendação: Use Edge TTS com processamento paralelo (padrão)")
        print("   - Já ativado por padrão no CLI")
        print("   - Configuração: edge_enable_parallel=True")
    elif fastest["engine"] == "Coqui TTS":
        print("✅ Recomendação: Use Coqui TTS para processamento local rápido")
        print("   - Não depende de conexão de rede")
        print("   - Requer instalação: pip install TTS")

    print()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
