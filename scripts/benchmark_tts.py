# -*- coding: utf-8 -*-
"""
Benchmark helper to compare TTS engines and multilingual strategies.

It measures chars/second for multiple scenarios:
  1. Edge baseline (no chunk optimisation)
  2. Edge optimised (project defaults)
  3. Edge aggressive chunking (smaller segments)
  4. Coqui XTTS v2 (if available)
  5. Piper (best matching model)
Additionally, it evaluates multilingual payloads twice:
  - Relying on engine automatic detection
  - Forcing language markup generated via LanguageDetector

Usage:
    python scripts/benchmark_tts.py --repeat 2 --multilingual

Notes:
  * Requires network access for Edge and downloads for Coqui/Piper models.
  * When a dependency/model is missing, that scenario is skipped gracefully.
"""

from __future__ import annotations

import argparse
import asyncio
import tempfile
import textwrap
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

from python_app.src.config import ConversionConfig, VoiceConfigProvider
from python_app.src.tts.factory import TTSFactory

try:
    from python_app.src.language.detector import LanguageDetector
except ImportError:  # pragma: no cover
    LanguageDetector = None  # type: ignore


BENCHMARK_TEXT_PT = textwrap.dedent(
    """
    O sol nascia preguiçoso sobre as colinas quando Elisa percebeu que tudo mudaria.
    Ela respirou fundo, sentiu o cheiro de café recém-passado e decidiu que estava pronta para sair da zona de conforto.
    Na biblioteca, arquivos empoeirados revelavam cartas apaixonadas, mapas rabiscados e receitas de família.
    Cada parágrafo parecia sussurrar segredos esquecidos.
    """
).strip()

BENCHMARK_TEXT_MULTI = textwrap.dedent(
    """
    Portuguese: Elisa abriu o diário antigo e encontrou anotações sobre uma viagem misteriosa.
    English: Moments later, she translated the passage and realised it referenced an island near Lisbon.
    Spanish: "Debes seguir las estrellas", decía la carta, mezclando consejos poéticos com coordenadas precisas.
    Portuguese: Determinada, ela preparou a mochila e prometeu escrever um novo capítulo para a família.
    """
).strip()


def _detected_markup(text: str) -> str:
    if LanguageDetector is None:
        return text
    detector = LanguageDetector()
    try:
        segments = detector.detect_language_segments(text, fallback_language="pt")
    except Exception:
        return text
    parts: List[str] = []
    for segment in segments:
        lang = (segment.language or "unknown").split("-", 1)[0]
        cleaned = segment.text.strip()
        if not cleaned:
            continue
        parts.append(f"[[lang:{lang}]]{cleaned}[[/lang]]")
    return "\n".join(parts) if parts else text


async def _synth(engine, payload: str) -> Tuple[float, Path]:
    payload = payload.strip()
    if not payload:
        raise ValueError("Benchmark payload cannot be empty.")
    tmp_handle = tempfile.NamedTemporaryFile(delete=False, suffix=".mp3")
    tmp_path = Path(tmp_handle.name)
    tmp_handle.close()
    start = time.perf_counter()
    await engine.synthesize_async(payload, tmp_path)
    elapsed = time.perf_counter() - start
    return elapsed, tmp_path


@dataclass
class Scenario:
    name: str
    engine: str
    description: str
    builder: Callable[[], object]
    text_variant: str  # 'pt', 'multi-auto', 'multi-detected'


def _edge_builder(
    voice: str, chunk_chars: Optional[int], max_secs: Optional[int]
) -> Callable[[], object]:
    from python_app.src.tts.edge_engine import EdgeTTSEngine

    def factory() -> object:
        return EdgeTTSEngine(
            voice,
            primary_language="pt-BR",
            language_voices={},
            verbose=True,
            chunk_char_limit=chunk_chars,
            max_segment_seconds=max_secs,
        )

    return factory


def _factory_builder(config: ConversionConfig) -> Callable[[], object]:
    tts_factory = TTSFactory()

    def factory() -> object:
        return tts_factory.create_engine(config)

    return factory


def build_scenarios(provider: VoiceConfigProvider) -> List[Scenario]:
    voice_edge = provider.get_voice("edge", "pt-BR") or "pt-BR-ThalitaMultilingualNeural"
    voice_coqui = (
        provider.get_voice("coqui", "pt-BR") or "tts_models/multilingual/multi-dataset/xtts_v2"
    )
    voice_piper = provider.get_voice("piper", "pt-BR")

    scenarios: List[Scenario] = [
        Scenario(
            name="edge-baseline",
            engine="edge",
            description="Edge sem chunk tuning",
            builder=_edge_builder(voice_edge, chunk_chars=None, max_secs=None),
            text_variant="pt",
        ),
        Scenario(
            name="edge-optimised",
            engine="edge",
            description="Edge com chunk 11k / 65s",
            builder=_edge_builder(voice_edge, chunk_chars=11_000, max_secs=65),
            text_variant="pt",
        ),
        Scenario(
            name="edge-aggressive",
            engine="edge",
            description="Edge chunk 8k / 40s",
            builder=_edge_builder(voice_edge, chunk_chars=8_000, max_secs=40),
            text_variant="multi-auto",
        ),
    ]

    # Coqui scenario
    config_coqui = ConversionConfig(engine="coqui", voice=voice_coqui, primary_language="pt-BR")
    scenarios.append(
        Scenario(
            name="coqui-xtts",
            engine="coqui",
            description="Coqui XTTS v2",
            builder=_factory_builder(config_coqui),
            text_variant="multi-auto",
        )
    )

    # Piper scenario (if model discovered)
    if voice_piper:
        config_piper = ConversionConfig(engine="piper", voice=voice_piper, primary_language="pt-BR")
        scenarios.append(
            Scenario(
                name="piper-default",
                engine="piper",
                description="Piper modelo detectado",
                builder=_factory_builder(config_piper),
                text_variant="pt",
            )
        )

    # Multilingual detection scenario using Edge
    scenarios.append(
        Scenario(
            name="edge-detected",
            engine="edge",
            description="Edge com LanguageDetector (markup)",
            builder=_edge_builder(voice_edge, chunk_chars=11_000, max_secs=65),
            text_variant="multi-detected",
        )
    )
    return scenarios


def select_text(variant: str, repeat: int) -> str:
    if variant == "multi-auto":
        return "\n\n".join([BENCHMARK_TEXT_MULTI] * repeat)
    if variant == "multi-detected":
        base = "\n\n".join([BENCHMARK_TEXT_MULTI] * repeat)
        return _detected_markup(base)
    return "\n\n".join([BENCHMARK_TEXT_PT] * repeat)


async def run_benchmarks(repeat: int, include_multilingual: bool) -> None:
    provider = VoiceConfigProvider()
    scenarios = build_scenarios(provider)
    results: List[Dict[str, object]] = []
    failures: List[str] = []

    for scenario in scenarios:
        if not include_multilingual and scenario.text_variant != "pt":
            continue
        payload = select_text(scenario.text_variant, repeat)
        try:
            engine = scenario.builder()
        except Exception as exc:
            msg = f"{scenario.name}: unable to prepare engine ({exc})"
            print(f"⚠️  {msg}")
            failures.append(msg)
            continue
        print(f"\n▶ Running {scenario.name} ({scenario.description}) …")
        try:
            elapsed, output_path = await _synth(engine, payload)
            throughput = len(payload) / elapsed if elapsed > 0 else 0.0
            results.append(
                {
                    "name": scenario.name,
                    "engine": scenario.engine,
                    "description": scenario.description,
                    "seconds": elapsed,
                    "chars_per_second": throughput,
                    "payload_chars": len(payload),
                    "text_variant": scenario.text_variant,
                    "output": str(output_path),
                }
            )
            print(f"   → {elapsed:.2f}s, {throughput:.1f} chars/s, file: {output_path}")
        except Exception as exc:
            msg = f"{scenario.name}: synthesis failed ({exc})"
            print(f"   ❌ {msg}")
            failures.append(msg)

    if not results:
        print("Nenhum benchmark foi executado com sucesso.")
        return

    print("\n=== Benchmark Summary ===")
    header = f"{'Scenario':<18}{'Engine':<8}{'Chars/s':>10}{'Seconds':>10}{'Variant':>12}"
    print(header)
    print("-" * len(header))
    sorted_rows = sorted(results, key=lambda r: r["chars_per_second"], reverse=True)
    for row in sorted_rows:
        print(
            f"{row['name']:<18}{row['engine']:<8}{row['chars_per_second']:>10.1f}"
            f"{row['seconds']:>10.2f}{row['text_variant']:>12}"
        )
    best = sorted_rows[0]
    print(
        f"\n🏆 Mais rápido: {best['name']} ({best['engine']}) → {best['chars_per_second']:.1f} chars/s "
        f"em {best['seconds']:.2f}s ({best['text_variant']})"
    )
    # Group by engine to show ranking summary
    per_engine: Dict[str, Dict[str, float]] = {}
    for row in sorted_rows:
        aggregate = per_engine.setdefault(row["engine"], {"chars": 0.0, "seconds": 0.0, "runs": 0})
        aggregate["chars"] += row["payload_chars"]
        aggregate["seconds"] += row["seconds"]
        aggregate["runs"] += 1
    print("\n=== Ranking por engine (média chars/s) ===")
    for engine, stats in sorted(
        per_engine.items(),
        key=lambda item: (item[1]["chars"] / item[1]["seconds"]) if item[1]["seconds"] else 0.0,
        reverse=True,
    ):
        avg = stats["chars"] / stats["seconds"] if stats["seconds"] else 0.0
        print(f" - {engine}: {avg:.1f} chars/s (runs={stats['runs']})")
    if failures:
        print("\n⚠️  Cenários com erro:")
        for item in failures:
            print(f"   • {item}")
    print("\nArquivos de áudio foram deixados em /tmp para verificação manual.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Benchmark Edge/Coqui/Piper engines and multilingual strategies."
    )
    parser.add_argument(
        "--repeat", type=int, default=2, help="Quantas vezes repetir o texto base em cada teste"
    )
    parser.add_argument(
        "--no-multilingual",
        action="store_true",
        help="Desabilita cenários com texto multilíngue e LanguageDetector",
    )
    args = parser.parse_args()
    repeat = max(1, args.repeat)
    asyncio.run(run_benchmarks(repeat, include_multilingual=not args.no_multilingual))


if __name__ == "__main__":
    main()
