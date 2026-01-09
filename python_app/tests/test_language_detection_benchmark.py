#!/usr/bin/env python3
"""
Benchmark: Language Detection + Specific Engines vs Multilingual Engines

This test compares two approaches:
1. Multilingual engines (Edge, Coqui XTTS) - use one engine for all languages
2. Language detection + specific engines (Piper, Kokoro) - detect language per sentence and route to the best engine for that language

Hypothesis: Language-specific engines may be faster and/or higher quality for their target languages.
"""

import asyncio
import importlib.util
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

# Add parent to path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from langdetect import LangDetectException, detect

# Test sentences in multiple languages
TEST_SENTENCES = {
    "pt": [
        "Olá, este é um teste em português brasileiro.",
        "A inteligência artificial está revolucionando o mundo.",
        "O Brasil é o maior país da América do Sul.",
    ],
    "en": [
        "Hello, this is a test in English.",
        "Artificial intelligence is changing the world rapidly.",
        "The quick brown fox jumps over the lazy dog.",
    ],
    "es": [
        "Hola, esta es una prueba en español.",
        "La tecnología avanza cada día más rápido.",
        "Madrid es la capital de España.",
    ],
    "ja": [
        "こんにちは、これは日本語のテストです。",
        "人工知能は世界を変えています。",
        "東京は日本の首都です。",
    ],
    "zh": [
        "你好，这是中文测试。",
        "人工智能正在改变世界。",
        "北京是中国的首都。",
    ],
}

# Engine capabilities per language
ENGINE_LANGUAGE_SUPPORT = {
    "piper": {"pt", "en"},  # Has good models for PT and EN
    "kokoro": {"en", "ja", "zh"},  # Supports EN, JA, ZH (82M model)
    "edge": {"pt", "en", "es", "ja", "zh", "fr", "de", "it"},  # Cloud, all languages
    "coqui": {"pt", "en", "es", "ja", "zh", "fr", "de", "it"},  # XTTS multilingual
}

# Best voice for each language per engine
LANGUAGE_VOICES = {
    "piper": {
        "pt": "pt_BR-faber-medium",
        "en": "en_US-lessac-medium",
    },
    "kokoro": {
        "en": "af_heart",  # American English
        "ja": "jf_alpha",  # Japanese
        "zh": "zf_xiaobei",  # Chinese
    },
    "edge": {
        "pt": "pt-BR-ThalitaMultilingualNeural",
        "en": "en-US-JennyNeural",
        "es": "es-ES-ElviraNeural",
        "ja": "ja-JP-NanamiNeural",
        "zh": "zh-CN-XiaoxiaoNeural",
    },
}


@dataclass
class BenchmarkResult:
    engine: str
    language: str
    approach: str  # "multilingual" or "detection"
    sentences: int
    total_chars: int
    total_time: float
    chars_per_second: float
    success_rate: float
    errors: List[str]


def detect_language(text: str) -> str:
    """Detect language of text using langdetect."""
    try:
        detected = detect(text)
        # Map some variants
        lang_map = {"pt": "pt", "en": "en", "es": "es", "ja": "ja", "zh-cn": "zh", "zh-tw": "zh"}
        return lang_map.get(detected, detected)
    except LangDetectException:
        return "en"  # Default fallback


def select_best_engine_for_language(lang: str, available_engines: List[str]) -> Tuple[str, str]:
    """
    Select the best engine for a specific language.
    Returns (engine_name, voice).

    Priority: Fast local engines > Slow local > Cloud
    """
    # Priority order for language-specific routing
    priority_order = ["kokoro", "piper", "edge", "coqui"]

    for engine in priority_order:
        if engine not in available_engines:
            continue
        if lang in ENGINE_LANGUAGE_SUPPORT.get(engine, set()):
            voice = LANGUAGE_VOICES.get(engine, {}).get(lang, "")
            return engine, voice

    # Fallback to Edge (multilingual)
    return "edge", LANGUAGE_VOICES.get("edge", {}).get(lang, "pt-BR-ThalitaMultilingualNeural")


async def benchmark_multilingual_engine(
    engine_name: str,
    sentences: Dict[str, List[str]],
    languages_to_test: List[str],
) -> List[BenchmarkResult]:
    """Benchmark a multilingual engine (one engine for all languages)."""
    results = []

    try:
        from src.config import ConversionConfig
        from src.tts.factory import TTSFactory

        factory = TTSFactory()

        for lang in languages_to_test:
            if lang not in sentences:
                continue
            if lang not in ENGINE_LANGUAGE_SUPPORT.get(engine_name, set()):
                continue

            lang_sentences = sentences[lang]
            voice = LANGUAGE_VOICES.get(engine_name, {}).get(lang, "")

            config = ConversionConfig(
                engine=engine_name,
                voice=voice,
                primary_language=lang,
                verbose=False,
            )

            try:
                engine = factory.create_engine(config)
            except Exception as e:
                results.append(
                    BenchmarkResult(
                        engine=engine_name,
                        language=lang,
                        approach="multilingual",
                        sentences=len(lang_sentences),
                        total_chars=sum(len(s) for s in lang_sentences),
                        total_time=0,
                        chars_per_second=0,
                        success_rate=0,
                        errors=[f"Failed to create engine: {e}"],
                    )
                )
                continue

            total_chars = 0
            total_time = 0
            successes = 0
            errors = []

            for sentence in lang_sentences:
                # Use .wav for Kokoro/Piper, .mp3 for Edge
                suffix = ".wav" if engine_name in ("kokoro", "piper") else ".mp3"
                with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
                    output_path = Path(f.name)

                try:
                    start = time.perf_counter()
                    await engine.synthesize_async(sentence, output_path)
                    elapsed = time.perf_counter() - start

                    # Check both possible output paths (.wav might be created even if .mp3 requested)
                    actual_path = output_path
                    wav_path = output_path.with_suffix(".wav")
                    if not actual_path.exists() and wav_path.exists():
                        actual_path = wav_path

                    if actual_path.exists() and actual_path.stat().st_size > 0:
                        total_time += elapsed
                        total_chars += len(sentence)
                        successes += 1
                    else:
                        errors.append(f"Empty output for: {sentence[:30]}...")
                except Exception as e:
                    errors.append(f"Error: {e}")
                finally:
                    # Cleanup both possible files
                    for p in [
                        output_path,
                        output_path.with_suffix(".wav"),
                        output_path.with_suffix(".mp3"),
                    ]:
                        if p.exists():
                            try:
                                p.unlink()
                            except Exception:
                                pass

            results.append(
                BenchmarkResult(
                    engine=engine_name,
                    language=lang,
                    approach="multilingual",
                    sentences=len(lang_sentences),
                    total_chars=total_chars,
                    total_time=total_time,
                    chars_per_second=total_chars / total_time if total_time > 0 else 0,
                    success_rate=successes / len(lang_sentences) if lang_sentences else 0,
                    errors=errors,
                )
            )

    except Exception as e:
        for lang in languages_to_test:
            if lang in sentences:
                results.append(
                    BenchmarkResult(
                        engine=engine_name,
                        language=lang,
                        approach="multilingual",
                        sentences=len(sentences[lang]),
                        total_chars=sum(len(s) for s in sentences[lang]),
                        total_time=0,
                        chars_per_second=0,
                        success_rate=0,
                        errors=[f"Engine setup failed: {e}"],
                    )
                )

    return results


async def benchmark_language_detection_approach(
    sentences: Dict[str, List[str]],
    available_engines: List[str],
) -> List[BenchmarkResult]:
    """
    Benchmark the language detection approach:
    - Detect language of each sentence
    - Route to the best available engine for that language
    """
    from src.config import ConversionConfig
    from src.tts.factory import TTSFactory

    factory = TTSFactory()
    results = []

    # Create all sentences flat list with their true language
    all_sentences = []
    for lang, sents in sentences.items():
        for s in sents:
            all_sentences.append((s, lang))

    # Group sentences by detected language and best engine
    engine_sentences: Dict[
        str, Dict[str, List[Tuple[str, str]]]
    ] = {}  # engine -> lang -> [(sentence, true_lang)]

    detection_times = []
    for sentence, true_lang in all_sentences:
        start = time.perf_counter()
        detected_lang = detect_language(sentence)
        detection_times.append(time.perf_counter() - start)

        best_engine, voice = select_best_engine_for_language(detected_lang, available_engines)

        if best_engine not in engine_sentences:
            engine_sentences[best_engine] = {}
        if detected_lang not in engine_sentences[best_engine]:
            engine_sentences[best_engine][detected_lang] = []

        engine_sentences[best_engine][detected_lang].append((sentence, true_lang, voice))

    avg_detection_time = sum(detection_times) / len(detection_times) if detection_times else 0
    print(f"\n📊 Language detection avg time: {avg_detection_time*1000:.2f}ms per sentence")

    # Now synthesize with each engine
    for engine_name, lang_groups in engine_sentences.items():
        for detected_lang, sentence_data in lang_groups.items():
            voice = sentence_data[0][2] if sentence_data else ""

            config = ConversionConfig(
                engine=engine_name,
                voice=voice,
                primary_language=detected_lang,
                verbose=False,
            )

            try:
                engine = factory.create_engine(config)
            except Exception as e:
                results.append(
                    BenchmarkResult(
                        engine=engine_name,
                        language=detected_lang,
                        approach="detection",
                        sentences=len(sentence_data),
                        total_chars=sum(len(s[0]) for s in sentence_data),
                        total_time=0,
                        chars_per_second=0,
                        success_rate=0,
                        errors=[f"Failed to create engine: {e}"],
                    )
                )
                continue

            total_chars = 0
            total_time = 0
            successes = 0
            errors = []

            for sentence, true_lang, _ in sentence_data:
                # Use .wav for Kokoro/Piper, .mp3 for Edge
                suffix = ".wav" if engine_name in ("kokoro", "piper") else ".mp3"
                with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
                    output_path = Path(f.name)

                try:
                    start = time.perf_counter()
                    await engine.synthesize_async(sentence, output_path)
                    elapsed = time.perf_counter() - start

                    # Check both possible output paths
                    actual_path = output_path
                    wav_path = output_path.with_suffix(".wav")
                    if not actual_path.exists() and wav_path.exists():
                        actual_path = wav_path

                    if actual_path.exists() and actual_path.stat().st_size > 0:
                        total_time += elapsed
                        total_chars += len(sentence)
                        successes += 1
                    else:
                        errors.append(f"Empty output for: {sentence[:30]}...")
                except Exception as e:
                    errors.append(f"Error: {e}")
                finally:
                    # Cleanup both possible files
                    for p in [
                        output_path,
                        output_path.with_suffix(".wav"),
                        output_path.with_suffix(".mp3"),
                    ]:
                        if p.exists():
                            try:
                                p.unlink()
                            except Exception:
                                pass

            results.append(
                BenchmarkResult(
                    engine=engine_name,
                    language=detected_lang,
                    approach="detection",
                    sentences=len(sentence_data),
                    total_chars=total_chars,
                    total_time=total_time,
                    chars_per_second=total_chars / total_time if total_time > 0 else 0,
                    success_rate=successes / len(sentence_data) if sentence_data else 0,
                    errors=errors,
                )
            )

    return results


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
            f"{r.engine:<12} {r.language:<6} {r.sentences:<10} {r.total_chars:<8} {r.total_time:<10.2f} {r.chars_per_second:<10.1f} {r.success_rate*100:<7.0f}%"
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
            f"{r.engine:<12} {r.language:<6} {r.sentences:<10} {r.total_chars:<8} {r.total_time:<10.2f} {r.chars_per_second:<10.1f} {r.success_rate*100:<7.0f}%"
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
            print(f"  Success rate: {success_rate*100:.0f}%")


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

    # Check Coqui
    if importlib.util.find_spec("TTS.api") is not None:
        # Don't add Coqui by default - it's very slow
        # available_engines.append("coqui")
        print("⚠️ Coqui: Available but skipped (very slow)")
    else:
        print("❌ Coqui: Not installed")

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
