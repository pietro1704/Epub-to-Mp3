"""Language detection approach strategy for the opt-in manual benchmark."""

from python_app.tests._language_detection_benchmark_selection import (
    detect_language as detect_language,
)
from python_app.tests._language_detection_benchmark_selection import (
    select_best_engine_for_language as select_best_engine_for_language,
)
from python_app.tests._language_detection_benchmark_support import (
    BenchmarkResult as BenchmarkResult,
)
from python_app.tests._language_detection_benchmark_support import Dict as Dict
from python_app.tests._language_detection_benchmark_support import List as List
from python_app.tests._language_detection_benchmark_support import Path as Path
from python_app.tests._language_detection_benchmark_support import Tuple as Tuple
from python_app.tests._language_detection_benchmark_support import tempfile as tempfile
from python_app.tests._language_detection_benchmark_support import time as time


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
    print(f"\n📊 Language detection avg time: {avg_detection_time * 1000:.2f}ms per sentence")

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
