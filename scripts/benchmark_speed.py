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
        print(f"⚠️ Coqui TTS not available: {e}")
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
        print(f"❌ File not found: {args.input_file}")
        return 1

    print("=" * 80)
    print("🚀 SPEED BENCHMARK - TTS ENGINES")
    print("=" * 80)
    print()

    # Load book
    print(f"📖 Loading book: {Path(args.input_file).name}")
    reader = EbookReader(args.input_file)
    chapters = list(reader.get_chapters())

    if not chapters:
        print("❌ No chapters found")
        return 1

    # Get sample text from first N chapters
    sample_text = ""
    for i, chapter in enumerate(chapters[: args.chapters]):
        if i >= args.chapters:
            break
        sample_text += chapter.text + "\n\n"

    chars_total = len(sample_text)
    print(f"📊 Test text: {args.chapters} chapters, {chars_total:,} characters")
    print()

    # Run benchmarks
    results = []

    print("⏱️ Testing Edge TTS (sequential mode)...")
    result_edge_seq = await benchmark_edge(sample_text, "sequential")
    results.append(result_edge_seq)
    print(
        f"   ✅ {result_edge_seq['duration']:.1f}s ({result_edge_seq['chars_per_sec']:.0f} chars/s)"
    )
    print()

    print("⏱️ Testing Edge TTS (parallel mode)...")
    result_edge_par = await benchmark_edge(sample_text, "parallel")
    results.append(result_edge_par)
    print(
        f"   ✅ {result_edge_par['duration']:.1f}s ({result_edge_par['chars_per_sec']:.0f} chars/s)"
    )
    print()

    if not args.skip_coqui:
        print("⏱️ Testing Coqui TTS...")
        result_coqui = await benchmark_coqui(sample_text)
        if result_coqui:
            results.append(result_coqui)
            print(
                f"   ✅ {result_coqui['duration']:.1f}s ({result_coqui['chars_per_sec']:.0f} chars/s)"
            )
        print()

    # Display results
    print("=" * 80)
    print("📊 BENCHMARK RESULTS")
    print("=" * 80)
    print()

    print(f"{'Engine':<20} {'Mode':<15} {'Time':<10} {'Chars/s':<12} {'Speedup'}")
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
    print("💡 RECOMMENDATIONS")
    print("=" * 80)
    print()

    # Find fastest
    fastest = min(results, key=lambda x: x["duration"])
    improvement = (baseline - fastest["duration"]) / baseline * 100

    print(f"🏆 Fastest engine: {fastest['engine']} ({fastest['mode']})")
    print(f"⚡ Improvement over baseline: {improvement:.1f}%")
    print()

    # Recommendations
    if fastest["engine"] == "Edge TTS" and fastest["mode"] == "parallel":
        print("✅ Recommendation: Use Edge TTS with parallel processing (default)")
        print("   - Already enabled by default in CLI")
        print("   - Config: edge_enable_parallel=True")
    elif fastest["engine"] == "Coqui TTS":
        print("✅ Recommendation: Use Coqui TTS for fast local processing")
        print("   - Does not depend on network connection")
        print("   - Requires install: pip install TTS")

    print()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
