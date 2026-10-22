"""Multilingual strategy for the opt-in manual benchmark."""

from python_app.tests._language_detection_benchmark_support import (
    BenchmarkResult as BenchmarkResult,
    Dict as Dict,
    ENGINE_LANGUAGE_SUPPORT as ENGINE_LANGUAGE_SUPPORT,
    LANGUAGE_VOICES as LANGUAGE_VOICES,
    List as List,
    Path as Path,
    tempfile as tempfile,
    time as time,
)

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
