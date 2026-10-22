#!/usr/bin/env python3
"""
Benchmark: Language Detection + Specific Engines vs Multilingual Engines

This test compares two approaches:
1. Multilingual engines (Edge) - use one engine for all languages
2. Language detection + specific engines (Piper, Kokoro) - detect language per sentence and route to the best engine for that language

Hypothesis: Language-specific engines may be faster and/or higher quality for their target languages.
"""


import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from python_app.tests._language_detection_benchmark_selection import (
    detect_language as detect_language,
)
from python_app.tests._language_detection_benchmark_selection import (
    select_best_engine_for_language as select_best_engine_for_language,
)
from python_app.tests._language_detection_benchmark_support import (
    ENGINE_LANGUAGE_SUPPORT as ENGINE_LANGUAGE_SUPPORT,
)
from python_app.tests._language_detection_benchmark_support import (
    LANGUAGE_VOICES as LANGUAGE_VOICES,
)
from python_app.tests._language_detection_benchmark_support import TEST_SENTENCES as TEST_SENTENCES
from python_app.tests._language_detection_benchmark_support import (
    BenchmarkResult as BenchmarkResult,
)
from python_app.tests._language_detection_benchmark_support import List as List
from python_app.tests._language_detection_benchmark_support import asyncio as asyncio
from python_app.tests._language_detection_benchmark_support import importlib as importlib
from python_app.tests._language_detection_language_detection_approach_benchmark import (
    benchmark_language_detection_approach as benchmark_language_detection_approach,
)
from python_app.tests._language_detection_multilingual_benchmark import (
    benchmark_multilingual_engine as benchmark_multilingual_engine,
)


def print_results(results: List[BenchmarkResult]):
    """Print benchmark results in a formatted table."""
    print("\n" + "=" * 80)
    print("BENCHMARK RESULTS: Language Detection + Specific Engines vs Multilingual")
    print("=" * 80)

    # Group by approach
    multilingual = [r for r in results if r.approach == "multilingual"]
    detection = [r for r in results if r.approach == "detection"]

    print("\n📊 MULTILINGUAL ENGINES (single engine for all languages):")
    print("-" * 70)
    print(
        f"{'Engine':<12} {'Lang':<6} {'Sentences':<10} {'Chars':<8} {'Time(s)':<10} {'Chars/s':<10} {'Success':<8}"
    )
    print("-" * 70)

    for r in sorted(multilingual, key=lambda x: (x.engine, x.language)):
        print(
            f"{r.engine:<12} {r.language:<6} {r.sentences:<10} {r.total_chars:<8} {r.total_time:<10.2f} {r.chars_per_second:<10.1f} {r.success_rate * 100:<7.0f}%"
        )
        if r.errors:
            for e in r.errors[:2]:
                print(f"   ⚠️ {e[:60]}")

    print("\n📊 DETECTION + SPECIFIC ENGINES (detect language, route to best engine):")
    print("-" * 70)
    print(
        f"{'Engine':<12} {'Lang':<6} {'Sentences':<10} {'Chars':<8} {'Time(s)':<10} {'Chars/s':<10} {'Success':<8}"
    )
    print("-" * 70)

    for r in sorted(detection, key=lambda x: (x.engine, x.language)):
        print(
            f"{r.engine:<12} {r.language:<6} {r.sentences:<10} {r.total_chars:<8} {r.total_time:<10.2f} {r.chars_per_second:<10.1f} {r.success_rate * 100:<7.0f}%"
        )
        if r.errors:
            for e in r.errors[:2]:
                print(f"   ⚠️ {e[:60]}")

    # Aggregate stats
    print("\n" + "=" * 80)
    print("AGGREGATE COMPARISON:")
    print("=" * 80)

    for approach, data in [("Multilingual", multilingual), ("Detection+Routing", detection)]:
        total_chars = sum(r.total_chars for r in data)
        total_time = sum(r.total_time for r in data)
        total_sentences = sum(r.sentences for r in data)
        successful = sum(r.sentences * r.success_rate for r in data)

        if total_time > 0:
            avg_speed = total_chars / total_time
            success_rate = successful / total_sentences if total_sentences > 0 else 0
            print(f"\n{approach}:")
            print(f"  Total sentences: {total_sentences}")
            print(f"  Total chars: {total_chars}")
            print(f"  Total time: {total_time:.2f}s")
            print(f"  Average speed: {avg_speed:.1f} chars/s")
            print(f"  Success rate: {success_rate * 100:.0f}%")


async def main():
    """Run the benchmark."""
    print("🔬 Starting Language Detection + Specific Engines Benchmark")
    print("=" * 80)

    # Check which engines are available
    available_engines = []

    # Check Edge (always available - cloud)
    if importlib.util.find_spec("edge_tts") is not None:
        available_engines.append("edge")
        print("✅ Edge-TTS: Available (cloud)")
    else:
        print("❌ Edge-TTS: Not installed")

    # Check Piper
    try:
        # Piper needs model files
        from src.tts.factory import TTSFactory

        factory = TTSFactory()
        try:
            factory._find_piper_model("pt")
            available_engines.append("piper")
            print("✅ Piper: Available (local ONNX)")
        except FileNotFoundError:
            print("⚠️ Piper: Installed but no models found")
    except ImportError:
        print("❌ Piper: Not installed")

    # Check Kokoro
    if importlib.util.find_spec("kokoro") is not None:
        available_engines.append("kokoro")
        print("✅ Kokoro: Available (82M local)")
    else:
        print("❌ Kokoro: Not installed")

    print(f"\n🔧 Testing with engines: {available_engines}")

    # Languages to test
    # For detection approach: only test languages that have at least one local engine
    detection_languages = ["pt", "en"]  # Piper supports these
    if "kokoro" in available_engines:
        detection_languages.extend(["ja", "zh"])

    # For multilingual: test all with Edge
    multilingual_languages = ["pt", "en", "es"]
    if "kokoro" in available_engines:
        multilingual_languages.extend(["ja", "zh"])

    all_results = []

    # 1. Test multilingual approach with Edge
    if "edge" in available_engines:
        print("\n\n🌐 Testing Edge-TTS (multilingual)...")
        edge_results = await benchmark_multilingual_engine(
            "edge", TEST_SENTENCES, multilingual_languages
        )
        all_results.extend(edge_results)

    # 2. Test language detection + routing approach
    print("\n\n🔍 Testing Language Detection + Routing...")
    # Only use local engines for the detection approach
    local_engines = [e for e in available_engines if e in ["piper", "kokoro"]]
    if local_engines:
        # Test sentences in languages supported by local engines
        test_sentences_subset = {
            k: v for k, v in TEST_SENTENCES.items() if k in detection_languages
        }
        detection_results = await benchmark_language_detection_approach(
            test_sentences_subset, local_engines
        )
        all_results.extend(detection_results)
    else:
        print("⚠️ No local engines available for detection approach")

    # Print results
    print_results(all_results)

    # Recommendations
    print("\n" + "=" * 80)
    print("📋 RECOMMENDATIONS:")
    print("=" * 80)

    # Calculate totals for comparison
    edge_results = [r for r in all_results if r.engine == "edge"]
    local_results = [r for r in all_results if r.engine in ["piper", "kokoro"]]

    edge_speed = sum(r.total_chars for r in edge_results) / max(
        sum(r.total_time for r in edge_results), 0.001
    )
    local_speed = sum(r.total_chars for r in local_results) / max(
        sum(r.total_time for r in local_results), 0.001
    )

    print(f"\n  Edge-TTS (cloud, multilingual): {edge_speed:.1f} chars/s")
    print(f"  Local engines (detection+routing): {local_speed:.1f} chars/s")

    if edge_speed > local_speed * 2:
        print("\n  ✅ RECOMMENDATION: Use Edge-TTS for best speed")
        print("     Edge is significantly faster and handles all languages")
    elif local_speed > edge_speed:
        print("\n  ✅ RECOMMENDATION: Use language detection + local engines")
        print("     Local engines are faster and work offline")
    else:
        print("\n  ✅ RECOMMENDATION: Use Edge-TTS for convenience")
        print("     Similar speed, but Edge handles more languages")

    print("\n  Note: Local engines (Piper, Kokoro) work offline and have no rate limits")
    print("        Edge-TTS requires internet but supports 100+ languages")


if __name__ == "__main__":
    asyncio.run(main())
