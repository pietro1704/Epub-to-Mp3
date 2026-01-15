# -*- coding: utf-8 -*-
"""
Benchmark Completo: Todas as Engines TTS com Multi-idioma

Testa:
- Edge-TTS, Coqui, Kokoro, Spark, Piper
- Detecção de idioma por frase
- Performance e throughput
- Suporte multilíngue

Uso:
    # Teste rápido (mock)
    python python_app/tests/test_all_engines_benchmark.py

    # Teste real
    python python_app/tests/test_all_engines_benchmark.py --real
"""

from __future__ import annotations

import asyncio
import importlib.util
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

# Lazy imports
langdetect = None
sf = None
np = None

try:
    import numpy as _np
    import soundfile as _sf

    np = _np
    sf = _sf
except ImportError:
    pass

try:
    from langdetect import detect as _detect

    langdetect = _detect
except ImportError:
    pass


# =============================================================================
# TEXTOS DE TESTE MULTI-IDIOMA
# =============================================================================

TEXTS = {
    "pt": """
O Brasil é o maior país da América do Sul, conhecido por sua biodiversidade única.
A floresta amazônica abriga milhões de espécies e é fundamental para o clima global.
O carnaval brasileiro é uma das maiores festas populares do mundo.
""",
    "en": """
The Amazon rainforest is the world's largest tropical rainforest.
It produces approximately twenty percent of the world's oxygen.
Scientists continue to discover new species within its vast expanse.
""",
    "es": """
El español es una de las lenguas más habladas del mundo.
América Latina tiene una rica diversidad cultural y natural.
La música latina ha conquistado audiencias en todo el planeta.
""",
    "fr": """
La France est connue pour sa cuisine raffinée et son art de vivre.
Paris est souvent appelée la ville lumière pour sa beauté architecturale.
Le français est parlé sur tous les continents du monde.
""",
    "de": """
Deutschland ist bekannt für seine Ingenieurskunst und Präzision.
Die deutsche Sprache hat viele zusammengesetzte Wörter.
Berlin ist eine Stadt voller Geschichte und Kultur.
""",
    "ja": """
日本は伝統と現代技術が融合した国です。
桜の季節は日本で最も美しい時期の一つです。
日本料理は世界中で人気があります。
""",
    "zh": """
中国是世界上人口最多的国家。
长城是人类历史上最伟大的建筑之一。
中国文化有着悠久的历史传统。
""",
}

# Texto misto para teste de detecção por frase
MIXED_TEXT = """
Hello, this is a test in English. The weather is nice today.
Olá, este é um teste em português. O clima está agradável.
Bonjour, ceci est un test en français. Le temps est beau.
Hola, esta es una prueba en español. El clima es agradable.
"""


@dataclass
class EngineResult:
    """Resultado de teste de uma engine."""

    engine: str
    language: str
    text_chars: int
    elapsed_seconds: float
    chars_per_second: float
    success: bool
    error: Optional[str] = None
    output_file: Optional[str] = None

    def __str__(self) -> str:
        status = "✓" if self.success else "✗"
        return (
            f"{status} {self.engine:10} | {self.language:5} | "
            f"{self.chars_per_second:8.1f} chars/s | "
            f"{self.elapsed_seconds:6.2f}s | {self.text_chars} chars"
        )


@dataclass
class EngineInfo:
    """Informações sobre uma engine."""

    name: str
    available: bool
    multilingual: bool
    languages: List[str]
    default_voice: str
    speed_estimate: str  # "fast", "medium", "slow"
    requires_gpu: bool = False
    requires_internet: bool = False


# =============================================================================
# DETECÇÃO DE ENGINE E CAPACIDADES
# =============================================================================


def detect_available_engines() -> Dict[str, EngineInfo]:
    """Detecta quais engines estão disponíveis."""
    engines = {}

    # Edge-TTS
    edge_available = importlib.util.find_spec("edge_tts") is not None
    engines["edge"] = EngineInfo(
        name="Edge-TTS",
        available=edge_available,
        multilingual=True,
        languages=["pt", "en", "es", "fr", "de", "ja", "zh"] if edge_available else [],
        default_voice="pt-BR-ThalitaMultilingualNeural" if edge_available else "",
        speed_estimate="fast",
        requires_internet=True,
    )

    # Coqui TTS
    coqui_available = importlib.util.find_spec("TTS.api") is not None
    engines["coqui"] = EngineInfo(
        name="Coqui XTTS",
        available=coqui_available,
        multilingual=True,
        languages=["pt", "en", "es", "fr", "de"] if coqui_available else [],
        default_voice="tts_models/multilingual/multi-dataset/xtts_v2" if coqui_available else "",
        speed_estimate="slow",
        requires_gpu=True,
    )

    # Kokoro
    kokoro_available = importlib.util.find_spec("kokoro") is not None
    engines["kokoro"] = EngineInfo(
        name="Kokoro",
        available=kokoro_available,
        multilingual=True,
        languages=["en", "ja", "zh"] if kokoro_available else [],
        default_voice="af_heart" if kokoro_available else "",
        speed_estimate="fast",
    )

    # Spark-TTS
    spark_available = (
        importlib.util.find_spec("torch") is not None
        and importlib.util.find_spec("huggingface_hub") is not None
    )

    engines["spark"] = EngineInfo(
        name="Spark-TTS",
        available=spark_available,
        multilingual=True,
        languages=["en", "zh"],
        default_voice="default",
        speed_estimate="slow",
        requires_gpu=True,
    )

    # Piper
    import shutil

    piper_available = shutil.which("piper") is not None
    engines["piper"] = EngineInfo(
        name="Piper",
        available=piper_available,
        multilingual=False,
        languages=["pt", "en"],
        default_voice="pt_BR-faber-medium.onnx",
        speed_estimate="medium",
    )

    return engines


def detect_sentence_language(sentence: str) -> str:
    """Detecta o idioma de uma frase."""
    if langdetect is None:
        return "en"  # fallback

    try:
        detected = langdetect(sentence)
        # Normaliza códigos
        lang_map = {
            "pt": "pt",
            "en": "en",
            "es": "es",
            "fr": "fr",
            "de": "de",
            "ja": "ja",
            "zh-cn": "zh",
            "zh-tw": "zh",
        }
        return lang_map.get(detected, detected)
    except Exception:
        return "en"


def split_by_language(text: str) -> List[Tuple[str, str]]:
    """Divide texto em segmentos por idioma detectado."""
    import re

    sentences = re.split(r"(?<=[.!?])\s+", text.strip())
    segments = []

    for sentence in sentences:
        sentence = sentence.strip()
        if not sentence:
            continue
        lang = detect_sentence_language(sentence)
        segments.append((lang, sentence))

    return segments


# =============================================================================
# FUNÇÕES DE SÍNTESE
# =============================================================================


async def synthesize_edge(text: str, language: str, output_path: Path) -> Tuple[bool, float]:
    """Sintetiza com Edge-TTS."""
    try:
        from python_app.src.tts.edge_engine import EdgeTTSEngine

        # Seleciona voz por idioma
        voices = {
            "pt": "pt-BR-ThalitaMultilingualNeural",
            "en": "en-US-JennyNeural",
            "es": "es-ES-ElviraNeural",
            "fr": "fr-FR-DeniseNeural",
            "de": "de-DE-KatjaNeural",
            "ja": "ja-JP-NanamiNeural",
            "zh": "zh-CN-XiaoxiaoNeural",
        }
        voice = voices.get(language, voices["en"])

        engine = EdgeTTSEngine(voice, primary_language=language)
        start = time.perf_counter()
        result = await engine.synthesize_async(text, output_path)
        elapsed = time.perf_counter() - start

        return result is not None and output_path.exists(), elapsed
    except Exception as e:
        print(f"    Edge error: {e}")
        return False, 0.0


async def synthesize_coqui(text: str, language: str, output_path: Path) -> Tuple[bool, float]:
    """Sintetiza com Coqui XTTS."""
    try:
        from python_app.src.tts.coqui_engine import CoquiTTSEngine

        engine = CoquiTTSEngine(
            "tts_models/multilingual/multi-dataset/xtts_v2", primary_language=language
        )

        start = time.perf_counter()
        result = await engine.synthesize_async(text, output_path)
        elapsed = time.perf_counter() - start

        return result is not None, elapsed
    except Exception as e:
        print(f"    Coqui error: {e}")
        return False, 0.0


async def synthesize_kokoro(text: str, language: str, output_path: Path) -> Tuple[bool, float]:
    """Sintetiza com Kokoro."""
    try:
        from python_app.src.tts.kokoro_engine import KokoroTTSEngine

        # Seleciona voz por idioma
        voices = {
            "en": "af_heart",
            "ja": "jf_alpha",
            "zh": "zf_xiaobei",
        }
        voice = voices.get(language, "af_heart")

        engine = KokoroTTSEngine(voice, primary_language=language)

        start = time.perf_counter()
        result = await engine.synthesize_async(text, output_path)
        elapsed = time.perf_counter() - start

        return result is not None and output_path.exists(), elapsed
    except Exception as e:
        print(f"    Kokoro error: {e}")
        return False, 0.0


async def synthesize_spark(text: str, language: str, output_path: Path) -> Tuple[bool, float]:
    """Sintetiza com Spark-TTS."""
    try:
        from python_app.src.tts.spark_engine import SparkTTSEngine

        engine = SparkTTSEngine("default", primary_language=language)

        start = time.perf_counter()
        result = await engine.synthesize_async(text, output_path)
        elapsed = time.perf_counter() - start

        return result is not None, elapsed
    except Exception as e:
        print(f"    Spark error: {e}")
        return False, 0.0


async def synthesize_piper(text: str, language: str, output_path: Path) -> Tuple[bool, float]:
    """Sintetiza com Piper."""
    try:
        from python_app.src.config import ConversionConfig
        from python_app.src.tts.factory import TTSFactory

        config = ConversionConfig(
            engine="piper",
            primary_language=language,
        )

        factory = TTSFactory()
        engine = factory.create_engine(config)

        start = time.perf_counter()
        result = await engine.synthesize_async(text, output_path)
        elapsed = time.perf_counter() - start

        return result is not None, elapsed
    except Exception as e:
        print(f"    Piper error: {e}")
        return False, 0.0


SYNTHESIZERS = {
    "edge": synthesize_edge,
    "coqui": synthesize_coqui,
    "kokoro": synthesize_kokoro,
    "spark": synthesize_spark,
    "piper": synthesize_piper,
}


# =============================================================================
# BENCHMARK PRINCIPAL
# =============================================================================


async def run_benchmark(real_mode: bool = False):
    """Executa benchmark completo de todas as engines."""
    print("\n" + "=" * 80)
    print("BENCHMARK COMPLETO: TODAS AS ENGINES TTS")
    print("=" * 80)

    # Detecta engines disponíveis
    engines = detect_available_engines()

    print("\n📋 ENGINES DETECTADAS:")
    print("-" * 80)
    for name, info in engines.items():
        status = "✓ Disponível" if info.available else "✗ Não instalada"
        gpu = " (GPU)" if info.requires_gpu else ""
        net = " (Internet)" if info.requires_internet else ""
        langs = ", ".join(info.languages) if info.languages else "N/A"
        print(f"  {info.name:15} | {status:20} | Idiomas: {langs}{gpu}{net}")

    available_engines = {k: v for k, v in engines.items() if v.available}

    if not available_engines:
        print("\n❌ Nenhuma engine disponível para teste!")
        return

    results: List[EngineResult] = []

    # Cria diretório temporário para outputs
    import tempfile

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # =================================================================
        # TESTE 1: Performance por idioma
        # =================================================================
        print("\n" + "=" * 80)
        print("TESTE 1: Performance por Idioma")
        print("=" * 80)

        for lang, text in TEXTS.items():
            text = text.strip()[:500]  # Limita tamanho para testes

            print(f"\n🌍 Idioma: {lang.upper()} ({len(text)} chars)")
            print("-" * 60)

            for engine_name, engine_info in available_engines.items():
                # Verifica se engine suporta o idioma
                if lang not in engine_info.languages and engine_info.languages:
                    print(f"  {engine_name:10} | ⏭️  Idioma não suportado")
                    continue

                output_file = temp_path / f"{engine_name}_{lang}.wav"

                if real_mode:
                    print(f"  {engine_name:10} | Sintetizando...", end=" ", flush=True)
                    synthesizer = SYNTHESIZERS.get(engine_name)
                    if synthesizer:
                        success, elapsed = await synthesizer(text, lang, output_file)
                        chars_per_sec = len(text) / elapsed if elapsed > 0 else 0

                        result = EngineResult(
                            engine=engine_name,
                            language=lang,
                            text_chars=len(text),
                            elapsed_seconds=elapsed,
                            chars_per_second=chars_per_sec,
                            success=success,
                            output_file=str(output_file) if success else None,
                        )
                        results.append(result)

                        status = "✓" if success else "✗"
                        print(f"{status} {chars_per_sec:.1f} chars/s ({elapsed:.2f}s)")
                else:
                    # Mock mode - simula performance
                    speed_map = {"fast": 200, "medium": 100, "slow": 10}
                    base_speed = speed_map.get(engine_info.speed_estimate, 100)
                    simulated_time = len(text) / base_speed

                    result = EngineResult(
                        engine=engine_name,
                        language=lang,
                        text_chars=len(text),
                        elapsed_seconds=simulated_time,
                        chars_per_second=base_speed,
                        success=True,
                    )
                    results.append(result)
                    print(f"  {engine_name:10} | ✓ ~{base_speed} chars/s (estimado)")

        # =================================================================
        # TESTE 2: Detecção de idioma por frase
        # =================================================================
        print("\n" + "=" * 80)
        print("TESTE 2: Detecção de Idioma por Frase")
        print("=" * 80)

        segments = split_by_language(MIXED_TEXT)

        print(f"\n📝 Texto misto dividido em {len(segments)} segmentos:")
        for lang, sentence in segments:
            print(f"  [{lang}] {sentence[:60]}...")

        if real_mode and "edge" in available_engines:
            print("\n🔄 Sintetizando com Edge-TTS (multilíngue)...")

            for i, (lang, sentence) in enumerate(segments):
                output_file = temp_path / f"mixed_edge_{i}_{lang}.wav"
                print(f"  Segmento {i + 1} [{lang}]...", end=" ", flush=True)

                success, elapsed = await synthesize_edge(sentence, lang, output_file)
                chars_per_sec = len(sentence) / elapsed if elapsed > 0 else 0
                status = "✓" if success else "✗"
                print(f"{status} {chars_per_sec:.1f} chars/s")

        # =================================================================
        # RESUMO DOS RESULTADOS
        # =================================================================
        print("\n" + "=" * 80)
        print("RESUMO DOS RESULTADOS")
        print("=" * 80)

        if results:
            # Agrupa por engine
            by_engine: Dict[str, List[EngineResult]] = {}
            for r in results:
                by_engine.setdefault(r.engine, []).append(r)

            print("\n📊 MÉDIA POR ENGINE:")
            print("-" * 60)

            engine_averages = []
            for engine_name, engine_results in by_engine.items():
                successful = [r for r in engine_results if r.success]
                if successful:
                    avg_speed = sum(r.chars_per_second for r in successful) / len(successful)
                    max_speed = max(r.chars_per_second for r in successful)
                    min_speed = min(r.chars_per_second for r in successful)
                    success_rate = len(successful) / len(engine_results) * 100

                    engine_averages.append(
                        (engine_name, avg_speed, max_speed, min_speed, success_rate)
                    )

                    print(
                        f"  {engine_name:10} | avg={avg_speed:7.1f} | max={max_speed:7.1f} | "
                        f"min={min_speed:7.1f} chars/s | {success_rate:.0f}% sucesso"
                    )

            # Ranking
            print("\n🏆 RANKING (por velocidade média):")
            print("-" * 60)

            engine_averages.sort(key=lambda x: x[1], reverse=True)
            for i, (name, avg, _, _, rate) in enumerate(engine_averages, 1):
                medal = ["🥇", "🥈", "🥉"][i - 1] if i <= 3 else f"{i}."
                print(f"  {medal} {name:10} | {avg:7.1f} chars/s | {rate:.0f}% sucesso")

            # Melhor por idioma
            print("\n🎯 MELHOR ENGINE POR IDIOMA:")
            print("-" * 60)

            by_lang: Dict[str, List[EngineResult]] = {}
            for r in results:
                if r.success:
                    by_lang.setdefault(r.language, []).append(r)

            for lang, lang_results in sorted(by_lang.items()):
                best = max(lang_results, key=lambda r: r.chars_per_second)
                print(f"  {lang:5} → {best.engine:10} ({best.chars_per_second:.1f} chars/s)")

            # Recomendação
            print("\n💡 RECOMENDAÇÃO:")
            print("-" * 60)
            if engine_averages:
                fastest = engine_averages[0][0]
                print(f"  Para máxima velocidade: {fastest.upper()}")

                quality_engines = ["coqui", "spark"]
                quality_available = [e for e, _, _, _, _ in engine_averages if e in quality_engines]
                if quality_available:
                    print(f"  Para máxima qualidade: {quality_available[0].upper()}")

                multilingual = [e for e, info in available_engines.items() if info.multilingual]
                if multilingual:
                    print(f"  Para múltiplos idiomas: {', '.join(m.upper() for m in multilingual)}")

    print("\n" + "=" * 80)
    print("BENCHMARK CONCLUÍDO")
    print("=" * 80)


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    real_mode = "--real" in sys.argv

    if real_mode:
        print("⚠️  Modo REAL ativado - testes com síntese real")
    else:
        print("ℹ️  Modo MOCK - use --real para testes reais")

    asyncio.run(run_benchmark(real_mode=real_mode))
