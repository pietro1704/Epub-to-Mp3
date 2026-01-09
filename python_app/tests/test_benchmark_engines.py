# -*- coding: utf-8 -*-
"""
Benchmark: Edge-TTS vs Coqui-TTS Performance Comparison

Testa ambos os engines com:
- Diferentes tamanhos de chunks
- Com e sem paralelismo
- Multi-idioma (PT-BR e EN-US)

Uso:
    pytest python_app/tests/test_benchmark_engines.py -v -s

    # Apenas benchmark rápido (mocked)
    pytest python_app/tests/test_benchmark_engines.py -v -s -k "mock"

    # Benchmark real (requer conexão/modelos)
    BENCHMARK_REAL=1 pytest python_app/tests/test_benchmark_engines.py -v -s -k "real"
"""

from __future__ import annotations

import asyncio
import os
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

import pytest

# Textos de teste multi-idioma
SAMPLE_TEXT_PT = """
O Brasil é um país de dimensões continentais, com uma biodiversidade única no mundo.
A floresta amazônica representa o maior bioma tropical do planeta, abrigando milhões
de espécies de plantas, animais e insetos. Os rios brasileiros são responsáveis por
uma parcela significativa da água doce disponível no mundo. A cultura brasileira é
marcada pela miscigenação de povos europeus, africanos e indígenas, resultando em
uma rica diversidade de manifestações artísticas, culinárias e religiosas. O carnaval,
o samba e a bossa nova são reconhecidos internacionalmente como símbolos da identidade
cultural brasileira. A economia do país é uma das maiores do hemisfério sul, com
destaque para a agricultura, mineração e indústria de transformação.
"""

SAMPLE_TEXT_EN = """
The Amazon rainforest is the world's largest tropical rainforest, covering over
five million square kilometers across nine countries. It produces approximately
twenty percent of the world's oxygen and houses an estimated ten percent of all
species on Earth. The forest plays a crucial role in regulating global climate
patterns and storing carbon dioxide. Indigenous communities have lived in harmony
with the forest for thousands of years, developing sustainable practices for
agriculture, hunting, and medicine. Conservation efforts are essential to preserve
this invaluable ecosystem for future generations. Scientists continue to discover
new species and potential medical compounds within its vast expanse.
"""

# Texto longo para testes de performance mais significativos
SAMPLE_TEXT_LONG_PT = SAMPLE_TEXT_PT * 5
SAMPLE_TEXT_LONG_EN = SAMPLE_TEXT_EN * 5


@dataclass
class BenchmarkResult:
    """Resultado de um benchmark individual."""

    engine: str
    language: str
    chunk_size: int
    parallelism: int
    text_chars: int
    elapsed_seconds: float
    audio_seconds: float
    chars_per_second: float
    success: bool
    error: Optional[str] = None

    def __str__(self) -> str:
        status = "✓" if self.success else "✗"
        return (
            f"{status} {self.engine:8} | {self.language:5} | "
            f"chunk={self.chunk_size:5} | parallel={self.parallelism} | "
            f"{self.chars_per_second:7.1f} chars/s | "
            f"{self.elapsed_seconds:6.2f}s"
        )


@dataclass
class BenchmarkConfig:
    """Configuração para um teste de benchmark."""

    engine: str
    language: str
    chunk_size: int
    parallelism: int
    text: str
    voice: Optional[str] = None


class BenchmarkRunner:
    """Executa benchmarks comparativos entre engines TTS."""

    def __init__(self, output_dir: Optional[Path] = None):
        self.output_dir = output_dir or Path(tempfile.mkdtemp())
        self.results: List[BenchmarkResult] = []

    async def run_edge_benchmark(
        self, config: BenchmarkConfig, mock_synthesis: bool = True
    ) -> BenchmarkResult:
        """Executa benchmark do Edge-TTS."""
        os.environ["EDGE_CHUNK_CHARS"] = str(config.chunk_size)
        os.environ["EDGE_MAX_CONCURRENCY"] = str(config.parallelism)

        text = config.text
        start_time = time.perf_counter()
        audio_duration = 0.0
        error = None
        success = True

        try:
            if mock_synthesis:
                # Simula síntese com tempo proporcional ao tamanho
                # Edge é rápido: ~200-400 chars/s dependendo de paralelismo
                base_speed = 150 if config.parallelism == 1 else 300
                simulated_time = len(text) / base_speed
                await asyncio.sleep(min(simulated_time, 0.5))  # Cap para testes rápidos
                audio_duration = len(text) / 15  # ~15 chars por segundo de áudio
            else:
                # Síntese real
                from src.tts.edge_engine import EdgeTTSEngine

                engine = EdgeTTSEngine()
                voice = config.voice or (
                    "pt-BR-FranciscaNeural" if config.language == "pt" else "en-US-JennyNeural"
                )

                output_path = (
                    self.output_dir
                    / f"edge_{config.language}_{config.chunk_size}_{config.parallelism}.mp3"
                )
                await engine.synthesize(text, str(output_path), voice=voice)

                # Calcula duração do áudio
                if output_path.exists():
                    import subprocess

                    result = subprocess.run(
                        [
                            "ffprobe",
                            "-v",
                            "error",
                            "-show_entries",
                            "format=duration",
                            "-of",
                            "default=noprint_wrappers=1:nokey=1",
                            str(output_path),
                        ],
                        capture_output=True,
                        text=True,
                    )
                    if result.returncode == 0:
                        audio_duration = float(result.stdout.strip())
        except Exception as e:
            success = False
            error = str(e)

        elapsed = time.perf_counter() - start_time
        chars_per_sec = len(text) / elapsed if elapsed > 0 else 0

        result = BenchmarkResult(
            engine="edge",
            language=config.language,
            chunk_size=config.chunk_size,
            parallelism=config.parallelism,
            text_chars=len(text),
            elapsed_seconds=elapsed,
            audio_seconds=audio_duration,
            chars_per_second=chars_per_sec,
            success=success,
            error=error,
        )
        self.results.append(result)
        return result

    async def run_coqui_benchmark(
        self, config: BenchmarkConfig, mock_synthesis: bool = True
    ) -> BenchmarkResult:
        """Executa benchmark do Coqui-TTS."""
        os.environ["COQUI_CHUNK_CHARS"] = str(config.chunk_size)
        os.environ["COQUI_MAX_WORKERS"] = str(config.parallelism)
        if config.parallelism == 1:
            os.environ["COQUI_SAFE_MODE"] = "1"
        else:
            os.environ.pop("COQUI_SAFE_MODE", None)

        text = config.text
        start_time = time.perf_counter()
        audio_duration = 0.0
        error = None
        success = True

        try:
            if mock_synthesis:
                # Simula síntese - Coqui é mais lento: ~50-100 chars/s
                base_speed = 40 if config.parallelism == 1 else 80
                simulated_time = len(text) / base_speed
                await asyncio.sleep(min(simulated_time, 1.0))  # Cap para testes rápidos
                audio_duration = len(text) / 15
            else:
                # Síntese real
                from src.tts.coqui_engine import CoquiTTSEngine

                engine = CoquiTTSEngine()

                output_path = (
                    self.output_dir
                    / f"coqui_{config.language}_{config.chunk_size}_{config.parallelism}.wav"
                )
                await engine.synthesize(text, str(output_path), language=config.language)

                # Calcula duração do áudio
                if output_path.exists():
                    import wave

                    with wave.open(str(output_path), "rb") as wf:
                        frames = wf.getnframes()
                        rate = wf.getframerate()
                        audio_duration = frames / rate
        except Exception as e:
            success = False
            error = str(e)

        elapsed = time.perf_counter() - start_time
        chars_per_sec = len(text) / elapsed if elapsed > 0 else 0

        result = BenchmarkResult(
            engine="coqui",
            language=config.language,
            chunk_size=config.chunk_size,
            parallelism=config.parallelism,
            text_chars=len(text),
            elapsed_seconds=elapsed,
            audio_seconds=audio_duration,
            chars_per_second=chars_per_sec,
            success=success,
            error=error,
        )
        self.results.append(result)
        return result

    def print_summary(self):
        """Imprime resumo dos resultados."""
        print("\n" + "=" * 80)
        print("BENCHMARK SUMMARY: Edge-TTS vs Coqui-TTS")
        print("=" * 80)

        # Agrupa por engine
        edge_results = [r for r in self.results if r.engine == "edge" and r.success]
        coqui_results = [r for r in self.results if r.engine == "coqui" and r.success]

        print("\n📊 RESULTADOS POR ENGINE:")
        print("-" * 80)

        for result in sorted(
            self.results, key=lambda r: (r.engine, r.language, -r.chars_per_second)
        ):
            print(result)

        print("\n📈 ESTATÍSTICAS AGREGADAS:")
        print("-" * 80)

        if edge_results:
            avg_edge = sum(r.chars_per_second for r in edge_results) / len(edge_results)
            max_edge = max(r.chars_per_second for r in edge_results)
            min_edge = min(r.chars_per_second for r in edge_results)
            print(
                f"Edge-TTS:  avg={avg_edge:7.1f} chars/s | max={max_edge:7.1f} | min={min_edge:7.1f}"
            )

        if coqui_results:
            avg_coqui = sum(r.chars_per_second for r in coqui_results) / len(coqui_results)
            max_coqui = max(r.chars_per_second for r in coqui_results)
            min_coqui = min(r.chars_per_second for r in coqui_results)
            print(
                f"Coqui-TTS: avg={avg_coqui:7.1f} chars/s | max={max_coqui:7.1f} | min={min_coqui:7.1f}"
            )

        if edge_results and coqui_results:
            speedup = avg_edge / avg_coqui if avg_coqui > 0 else 0
            print(f"\n🏆 Edge-TTS é {speedup:.1f}x mais rápido que Coqui-TTS (média)")

        # Melhor configuração por engine
        print("\n🎯 MELHOR CONFIGURAÇÃO POR ENGINE:")
        print("-" * 80)

        if edge_results:
            best_edge = max(edge_results, key=lambda r: r.chars_per_second)
            print(
                f"Edge-TTS:  chunk={best_edge.chunk_size}, parallel={best_edge.parallelism} "
                f"→ {best_edge.chars_per_second:.1f} chars/s"
            )

        if coqui_results:
            best_coqui = max(coqui_results, key=lambda r: r.chars_per_second)
            print(
                f"Coqui-TTS: chunk={best_coqui.chunk_size}, parallel={best_coqui.parallelism} "
                f"→ {best_coqui.chars_per_second:.1f} chars/s"
            )

        # Impacto do paralelismo
        print("\n⚡ IMPACTO DO PARALELISMO:")
        print("-" * 80)

        for engine in ["edge", "coqui"]:
            engine_results = [r for r in self.results if r.engine == engine and r.success]
            serial = [r for r in engine_results if r.parallelism == 1]
            parallel = [r for r in engine_results if r.parallelism > 1]

            if serial and parallel:
                avg_serial = sum(r.chars_per_second for r in serial) / len(serial)
                avg_parallel = sum(r.chars_per_second for r in parallel) / len(parallel)
                gain = ((avg_parallel - avg_serial) / avg_serial) * 100 if avg_serial > 0 else 0
                print(
                    f"{engine:8}: serial={avg_serial:.1f} chars/s → parallel={avg_parallel:.1f} chars/s "
                    f"(+{gain:.0f}% ganho)"
                )

        print("\n" + "=" * 80)


# =============================================================================
# TESTES COM MOCK (rápidos, sem dependências externas)
# =============================================================================


class TestBenchmarkMocked:
    """Testes de benchmark com síntese mockada (rápidos)."""

    @pytest.fixture
    def runner(self, tmp_path):
        return BenchmarkRunner(output_dir=tmp_path)

    @pytest.mark.asyncio
    async def test_edge_vs_coqui_mock_pt(self, runner):
        """Benchmark mockado Edge vs Coqui em Português."""
        configs = [
            # Edge com diferentes configurações
            BenchmarkConfig("edge", "pt", chunk_size=2000, parallelism=1, text=SAMPLE_TEXT_PT),
            BenchmarkConfig("edge", "pt", chunk_size=4000, parallelism=1, text=SAMPLE_TEXT_PT),
            BenchmarkConfig("edge", "pt", chunk_size=4000, parallelism=4, text=SAMPLE_TEXT_PT),
            BenchmarkConfig("edge", "pt", chunk_size=8000, parallelism=8, text=SAMPLE_TEXT_PT),
            # Coqui com diferentes configurações
            BenchmarkConfig("coqui", "pt", chunk_size=1500, parallelism=1, text=SAMPLE_TEXT_PT),
            BenchmarkConfig("coqui", "pt", chunk_size=2800, parallelism=1, text=SAMPLE_TEXT_PT),
            BenchmarkConfig("coqui", "pt", chunk_size=2800, parallelism=4, text=SAMPLE_TEXT_PT),
        ]

        for config in configs:
            if config.engine == "edge":
                await runner.run_edge_benchmark(config, mock_synthesis=True)
            else:
                await runner.run_coqui_benchmark(config, mock_synthesis=True)

        runner.print_summary()

        # Verificações
        assert len(runner.results) == len(configs)
        assert all(r.success for r in runner.results)

    @pytest.mark.asyncio
    async def test_edge_vs_coqui_mock_en(self, runner):
        """Benchmark mockado Edge vs Coqui em Inglês."""
        configs = [
            BenchmarkConfig("edge", "en", chunk_size=4000, parallelism=1, text=SAMPLE_TEXT_EN),
            BenchmarkConfig("edge", "en", chunk_size=4000, parallelism=4, text=SAMPLE_TEXT_EN),
            BenchmarkConfig("coqui", "en", chunk_size=2800, parallelism=1, text=SAMPLE_TEXT_EN),
            BenchmarkConfig("coqui", "en", chunk_size=2800, parallelism=4, text=SAMPLE_TEXT_EN),
        ]

        for config in configs:
            if config.engine == "edge":
                await runner.run_edge_benchmark(config, mock_synthesis=True)
            else:
                await runner.run_coqui_benchmark(config, mock_synthesis=True)

        runner.print_summary()
        assert all(r.success for r in runner.results)

    @pytest.mark.asyncio
    async def test_parallelism_impact_mock(self, runner):
        """Testa impacto do paralelismo (mock)."""
        text = SAMPLE_TEXT_LONG_PT

        # Edge: serial vs parallel
        await runner.run_edge_benchmark(
            BenchmarkConfig("edge", "pt", chunk_size=4000, parallelism=1, text=text),
            mock_synthesis=True,
        )
        await runner.run_edge_benchmark(
            BenchmarkConfig("edge", "pt", chunk_size=4000, parallelism=8, text=text),
            mock_synthesis=True,
        )

        # Coqui: serial vs parallel
        await runner.run_coqui_benchmark(
            BenchmarkConfig("coqui", "pt", chunk_size=2800, parallelism=1, text=text),
            mock_synthesis=True,
        )
        await runner.run_coqui_benchmark(
            BenchmarkConfig("coqui", "pt", chunk_size=2800, parallelism=4, text=text),
            mock_synthesis=True,
        )

        runner.print_summary()

        # Verifica que paralelismo melhora performance
        edge_serial = runner.results[0]
        edge_parallel = runner.results[1]
        assert edge_parallel.chars_per_second >= edge_serial.chars_per_second

    @pytest.mark.asyncio
    async def test_chunk_size_impact_mock(self, runner):
        """Testa impacto do tamanho de chunk (mock)."""
        text = SAMPLE_TEXT_LONG_PT

        chunk_sizes = [2000, 4000, 6000, 8000]

        for chunk_size in chunk_sizes:
            await runner.run_edge_benchmark(
                BenchmarkConfig("edge", "pt", chunk_size=chunk_size, parallelism=4, text=text),
                mock_synthesis=True,
            )

        runner.print_summary()
        assert len(runner.results) == len(chunk_sizes)


# =============================================================================
# TESTES REAIS (requerem conexão/modelos instalados)
# =============================================================================


class TestBenchmarkReal:
    """Testes de benchmark com síntese real."""

    @pytest.fixture
    def runner(self, tmp_path):
        return BenchmarkRunner(output_dir=tmp_path)

    @pytest.mark.asyncio
    async def test_edge_real_pt(self, runner):
        """Benchmark real Edge-TTS em Português."""
        use_real = os.environ.get("BENCHMARK_REAL") == "1"
        configs = [
            BenchmarkConfig("edge", "pt", chunk_size=4000, parallelism=1, text=SAMPLE_TEXT_PT),
            BenchmarkConfig("edge", "pt", chunk_size=4000, parallelism=4, text=SAMPLE_TEXT_PT),
            BenchmarkConfig("edge", "pt", chunk_size=8000, parallelism=8, text=SAMPLE_TEXT_PT),
        ]

        for config in configs:
            result = await runner.run_edge_benchmark(config, mock_synthesis=not use_real)
            print(result)

        runner.print_summary()

    @pytest.mark.asyncio
    async def test_coqui_real_pt(self, runner):
        """Benchmark real Coqui-TTS em Português."""
        use_real = os.environ.get("BENCHMARK_REAL") == "1"
        configs = [
            BenchmarkConfig(
                "coqui", "pt", chunk_size=1500, parallelism=1, text=SAMPLE_TEXT_PT[:500]
            ),
            BenchmarkConfig(
                "coqui", "pt", chunk_size=2800, parallelism=2, text=SAMPLE_TEXT_PT[:500]
            ),
        ]

        for config in configs:
            result = await runner.run_coqui_benchmark(config, mock_synthesis=not use_real)
            print(result)

        runner.print_summary()

    @pytest.mark.asyncio
    async def test_full_comparison_real(self, runner):
        """Comparação completa real Edge vs Coqui."""
        use_real = os.environ.get("BENCHMARK_REAL") == "1"
        text = SAMPLE_TEXT_PT[:800]  # Texto menor para testes reais

        configs = [
            # Edge
            BenchmarkConfig("edge", "pt", chunk_size=4000, parallelism=1, text=text),
            BenchmarkConfig("edge", "pt", chunk_size=4000, parallelism=4, text=text),
            # Coqui
            BenchmarkConfig("coqui", "pt", chunk_size=2800, parallelism=1, text=text),
            BenchmarkConfig("coqui", "pt", chunk_size=2800, parallelism=2, text=text),
        ]

        for config in configs:
            if config.engine == "edge":
                await runner.run_edge_benchmark(config, mock_synthesis=not use_real)
            else:
                await runner.run_coqui_benchmark(config, mock_synthesis=not use_real)

        runner.print_summary()


# =============================================================================
# SCRIPT DE BENCHMARK STANDALONE
# =============================================================================


async def run_full_benchmark(real: bool = False):
    """Executa benchmark completo comparativo."""
    print("\n" + "🔬 " * 20)
    print("BENCHMARK COMPARATIVO: Edge-TTS vs Coqui-TTS")
    print("🔬 " * 20 + "\n")

    runner = BenchmarkRunner()

    # Configurações de teste
    languages = [("pt", SAMPLE_TEXT_PT), ("en", SAMPLE_TEXT_EN)]
    edge_configs = [(2000, 1), (4000, 1), (4000, 4), (6000, 4), (8000, 8)]
    coqui_configs = [(1500, 1), (2800, 1), (2800, 2), (2800, 4)]

    total_tests = len(languages) * (len(edge_configs) + len(coqui_configs))
    current = 0

    for lang, text in languages:
        print(f"\n📌 Testando idioma: {lang.upper()}")
        print("-" * 40)

        # Edge benchmarks
        for chunk, parallel in edge_configs:
            current += 1
            print(f"[{current}/{total_tests}] Edge chunk={chunk} parallel={parallel}...", end=" ")
            result = await runner.run_edge_benchmark(
                BenchmarkConfig("edge", lang, chunk, parallel, text), mock_synthesis=not real
            )
            print(f"{result.chars_per_second:.1f} chars/s")

        # Coqui benchmarks
        for chunk, parallel in coqui_configs:
            current += 1
            print(f"[{current}/{total_tests}] Coqui chunk={chunk} parallel={parallel}...", end=" ")
            result = await runner.run_coqui_benchmark(
                BenchmarkConfig("coqui", lang, chunk, parallel, text), mock_synthesis=not real
            )
            print(f"{result.chars_per_second:.1f} chars/s")

    runner.print_summary()
    return runner


if __name__ == "__main__":
    import sys

    real_mode = "--real" in sys.argv or os.environ.get("BENCHMARK_REAL") == "1"

    if real_mode:
        print("⚠️  Modo REAL ativado - requer Edge-TTS online e Coqui instalado")
    else:
        print("ℹ️  Modo MOCK - use --real ou BENCHMARK_REAL=1 para testes reais")

    asyncio.run(run_full_benchmark(real=real_mode))
