#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Benchmark de Conversao TTS - Testa diferentes combinacoes de parametros.

Compara velocidade de conversao com diferentes configuracoes:
- Baseline (sem otimizacoes)
- Diferentes tamanhos de chunk
- Diferentes niveis de concurrency
- Com/sem paralelismo de segmentos
- Combinacoes otimizadas

Uso:
    python benchmark_conversion.py livro.epub [--engine edge] [--chapters 10]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Adiciona o diretorio do projeto ao path
sys.path.insert(0, str(Path(__file__).parent))

from python_app.src.config import AppConfig
from python_app.src.ebook_reader import EbookReader
from python_app.src.tts.edge_engine import (
    reset_adaptive_settings,
)
from python_app.src.tts.factory import TTSFactory


@dataclass
class BenchmarkConfig:
    """Configuracao para um teste de benchmark."""

    name: str
    description: str
    chunk_chars: int = 8000
    max_segment_seconds: int = 65
    concurrency: int = 4
    enable_parallel: bool = True
    batch_delay_ms: int = 0
    safe_mode: Optional[bool] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "chunk_chars": self.chunk_chars,
            "max_segment_seconds": self.max_segment_seconds,
            "concurrency": self.concurrency,
            "enable_parallel": self.enable_parallel,
            "batch_delay_ms": self.batch_delay_ms,
            "safe_mode": self.safe_mode,
        }


@dataclass
class BenchmarkResult:
    """Resultado de um teste de benchmark."""

    config: BenchmarkConfig
    chapters_converted: int
    total_chars: int
    total_time: float  # segundos
    chars_per_second: float
    success_rate: float
    errors: List[str] = field(default_factory=list)
    chapter_times: List[float] = field(default_factory=list)

    @property
    def avg_chapter_time(self) -> float:
        if not self.chapter_times:
            return 0.0
        return sum(self.chapter_times) / len(self.chapter_times)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "config": self.config.to_dict(),
            "chapters_converted": self.chapters_converted,
            "total_chars": self.total_chars,
            "total_time_seconds": round(self.total_time, 2),
            "chars_per_second": round(self.chars_per_second, 1),
            "success_rate": round(self.success_rate * 100, 1),
            "avg_chapter_time_seconds": round(self.avg_chapter_time, 2),
            "errors_count": len(self.errors),
        }


# ============================================================================
# CONFIGURACOES DE BENCHMARK (EDGE)
# ============================================================================

# Baseline - sem otimizacoes
BASELINE_CONFIG = BenchmarkConfig(
    name="baseline",
    description="Sem otimizacoes (chunk pequeno, sem paralelismo)",
    chunk_chars=4000,
    max_segment_seconds=45,
    concurrency=1,
    enable_parallel=False,
    batch_delay_ms=0,
)

# Configuracoes de teste para chunk size
CHUNK_CONFIGS = [
    BenchmarkConfig(
        name="chunk_6k",
        description="Chunk 6000 chars",
        chunk_chars=6000,
        concurrency=4,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="chunk_8k",
        description="Chunk 8000 chars",
        chunk_chars=8000,
        concurrency=4,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="chunk_10k",
        description="Chunk 10000 chars",
        chunk_chars=10000,
        concurrency=4,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="chunk_12k",
        description="Chunk 12000 chars",
        chunk_chars=12000,
        concurrency=4,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="chunk_15k",
        description="Chunk 15000 chars (max seguro)",
        chunk_chars=15000,
        concurrency=4,
        enable_parallel=True,
    ),
]

# Configuracoes de teste para concurrency
CONCURRENCY_CONFIGS = [
    BenchmarkConfig(
        name="conc_2",
        description="Concurrency 2",
        chunk_chars=10000,
        concurrency=2,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="conc_3",
        description="Concurrency 3",
        chunk_chars=10000,
        concurrency=3,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="conc_4",
        description="Concurrency 4",
        chunk_chars=10000,
        concurrency=4,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="conc_5",
        description="Concurrency 5",
        chunk_chars=10000,
        concurrency=5,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="conc_6",
        description="Concurrency 6",
        chunk_chars=10000,
        concurrency=6,
        enable_parallel=True,
    ),
]

# Configuracoes de teste para paralelismo
PARALLEL_CONFIGS = [
    BenchmarkConfig(
        name="no_parallel",
        description="Sem paralelismo de segmentos",
        chunk_chars=10000,
        concurrency=4,
        enable_parallel=False,
    ),
    BenchmarkConfig(
        name="with_parallel",
        description="Com paralelismo de segmentos",
        chunk_chars=10000,
        concurrency=4,
        enable_parallel=True,
    ),
]

# Configuracoes combinadas otimizadas
OPTIMIZED_CONFIGS = [
    BenchmarkConfig(
        name="conservative",
        description="Conservador (chunk 6k, conc 3)",
        chunk_chars=6000,
        max_segment_seconds=55,
        concurrency=3,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="balanced",
        description="Balanceado (chunk 8k, conc 4)",
        chunk_chars=8000,
        max_segment_seconds=65,
        concurrency=4,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="aggressive",
        description="Agressivo (chunk 10k, conc 5)",
        chunk_chars=10000,
        max_segment_seconds=75,
        concurrency=5,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="ultra_aggressive",
        description="Ultra agressivo (chunk 12k, conc 6)",
        chunk_chars=12000,
        max_segment_seconds=85,
        concurrency=6,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="max_speed",
        description="Velocidade maxima (chunk 15k, conc 6)",
        chunk_chars=15000,
        max_segment_seconds=90,
        concurrency=6,
        enable_parallel=True,
    ),
]

# Configuracoes adicionais para Edge (mais agressivas)
EDGE_TURBO_CONFIGS = [
    BenchmarkConfig(
        name="edge_turbo_7",
        description="Edge turbo (chunk 12k, conc 7)",
        chunk_chars=12000,
        max_segment_seconds=90,
        concurrency=7,
        enable_parallel=True,
    ),
    BenchmarkConfig(
        name="edge_turbo_8",
        description="Edge turbo (chunk 12k, conc 8)",
        chunk_chars=12000,
        max_segment_seconds=95,
        concurrency=8,
        enable_parallel=True,
    ),
]

# Todas as configuracoes Edge
ALL_CONFIGS = [
    BASELINE_CONFIG,
    *CHUNK_CONFIGS,
    *CONCURRENCY_CONFIGS,
    *PARALLEL_CONFIGS,
    *OPTIMIZED_CONFIGS,
    *EDGE_TURBO_CONFIGS,
]


def build_edge_exhaustive_configs() -> List[BenchmarkConfig]:
    """Generate a full grid of Edge configs for exhaustive benchmarking."""
    chunk_sizes = [4000, 6000, 8000, 10000, 12000, 15000]
    concurrencies = list(range(1, 9))
    parallels = [False, True]
    max_segment_seconds_options = [45, 65, 85]
    batch_delays = [0, 250, 500]

    configs: List[BenchmarkConfig] = []
    for chunk_chars in chunk_sizes:
        for concurrency in concurrencies:
            for enable_parallel in parallels:
                for max_segment_seconds in max_segment_seconds_options:
                    for batch_delay_ms in batch_delays:
                        name = (
                            f"edge_c{chunk_chars}_n{concurrency}_"
                            f"p{int(enable_parallel)}_s{max_segment_seconds}_"
                            f"d{batch_delay_ms}"
                        )
                        description = (
                            f"Edge chunk {chunk_chars}, conc {concurrency}, "
                            f"parallel {enable_parallel}, seg {max_segment_seconds}s, "
                            f"delay {batch_delay_ms}ms"
                        )
                        configs.append(
                            BenchmarkConfig(
                                name=name,
                                description=description,
                                chunk_chars=chunk_chars,
                                max_segment_seconds=max_segment_seconds,
                                concurrency=concurrency,
                                enable_parallel=enable_parallel,
                                batch_delay_ms=batch_delay_ms,
                            )
                        )
    return configs


# ============================================================================
# CONFIGURACOES DE BENCHMARK (COQUI)
# ============================================================================

COQUI_BASELINE_CONFIG = BenchmarkConfig(
    name="coqui_baseline",
    description="Coqui baseline (chunk 2500, 1 worker, safe mode)",
    chunk_chars=2500,
    concurrency=1,
    enable_parallel=False,
    safe_mode=True,
)

COQUI_CHUNK_CONFIGS = [
    BenchmarkConfig(
        name="coqui_chunk_2k",
        description="Coqui chunk 2000",
        chunk_chars=2000,
        concurrency=2,
        enable_parallel=False,
        safe_mode=False,
    ),
    BenchmarkConfig(
        name="coqui_chunk_3k",
        description="Coqui chunk 3000",
        chunk_chars=3000,
        concurrency=2,
        enable_parallel=False,
        safe_mode=False,
    ),
    BenchmarkConfig(
        name="coqui_chunk_4k",
        description="Coqui chunk 4000",
        chunk_chars=4000,
        concurrency=2,
        enable_parallel=False,
        safe_mode=False,
    ),
    BenchmarkConfig(
        name="coqui_chunk_6k",
        description="Coqui chunk 6000",
        chunk_chars=6000,
        concurrency=2,
        enable_parallel=False,
        safe_mode=False,
    ),
]

COQUI_WORKER_CONFIGS = [
    BenchmarkConfig(
        name="coqui_workers_1",
        description="Coqui 1 worker (safe off)",
        chunk_chars=3000,
        concurrency=1,
        enable_parallel=False,
        safe_mode=False,
    ),
    BenchmarkConfig(
        name="coqui_workers_2",
        description="Coqui 2 workers",
        chunk_chars=3000,
        concurrency=2,
        enable_parallel=False,
        safe_mode=False,
    ),
    BenchmarkConfig(
        name="coqui_workers_3",
        description="Coqui 3 workers",
        chunk_chars=3000,
        concurrency=3,
        enable_parallel=False,
        safe_mode=False,
    ),
    BenchmarkConfig(
        name="coqui_workers_4",
        description="Coqui 4 workers",
        chunk_chars=3000,
        concurrency=4,
        enable_parallel=False,
        safe_mode=False,
    ),
]

COQUI_OPTIMIZED_CONFIGS = [
    BenchmarkConfig(
        name="coqui_balanced",
        description="Coqui balanceado (chunk 3k, 2 workers)",
        chunk_chars=3000,
        concurrency=2,
        enable_parallel=False,
        safe_mode=False,
    ),
    BenchmarkConfig(
        name="coqui_aggressive",
        description="Coqui agressivo (chunk 4k, 3 workers)",
        chunk_chars=4000,
        concurrency=3,
        enable_parallel=False,
        safe_mode=False,
    ),
    BenchmarkConfig(
        name="coqui_max",
        description="Coqui max (chunk 6k, 4 workers)",
        chunk_chars=6000,
        concurrency=4,
        enable_parallel=False,
        safe_mode=False,
    ),
]

# Todas as configuracoes Coqui
COQUI_ALL_CONFIGS = [
    COQUI_BASELINE_CONFIG,
    *COQUI_CHUNK_CONFIGS,
    *COQUI_WORKER_CONFIGS,
    *COQUI_OPTIMIZED_CONFIGS,
]

# ============================================================================
# CONFIGURACOES DE BENCHMARK (PIPER)
# ============================================================================

PIPER_BASELINE_CONFIG = BenchmarkConfig(
    name="piper_baseline",
    description="Piper baseline (1 processo)",
    chunk_chars=4000,
    concurrency=1,
    enable_parallel=False,
)

PIPER_PROCS_CONFIGS = [
    BenchmarkConfig(
        name="piper_procs_1",
        description="Piper 1 processo",
        chunk_chars=4000,
        concurrency=1,
        enable_parallel=False,
    ),
    BenchmarkConfig(
        name="piper_procs_2",
        description="Piper 2 processos",
        chunk_chars=4000,
        concurrency=2,
        enable_parallel=False,
    ),
    BenchmarkConfig(
        name="piper_procs_3",
        description="Piper 3 processos",
        chunk_chars=4000,
        concurrency=3,
        enable_parallel=False,
    ),
    BenchmarkConfig(
        name="piper_procs_4",
        description="Piper 4 processos",
        chunk_chars=4000,
        concurrency=4,
        enable_parallel=False,
    ),
]

PIPER_OPTIMIZED_CONFIGS = [
    BenchmarkConfig(
        name="piper_balanced",
        description="Piper balanceado (2 processos)",
        chunk_chars=4000,
        concurrency=2,
        enable_parallel=False,
    ),
    BenchmarkConfig(
        name="piper_aggressive",
        description="Piper agressivo (3 processos)",
        chunk_chars=4000,
        concurrency=3,
        enable_parallel=False,
    ),
]

PIPER_ALL_CONFIGS = [
    PIPER_BASELINE_CONFIG,
    *PIPER_PROCS_CONFIGS,
    *PIPER_OPTIMIZED_CONFIGS,
]


class ConversionBenchmark:
    """Executor de benchmark de conversao TTS."""

    def __init__(
        self,
        book_path: Path,
        engine: str = "edge",
        num_chapters: int = 10,
        voice: Optional[str] = None,
        verbose: bool = False,
        autosave_path: Optional[Path] = None,
        chapter_timeout: float = 300.0,
    ):
        self.book_path = Path(book_path)
        self.engine = engine
        self.num_chapters = num_chapters
        self.voice = voice
        self.verbose = verbose
        self.autosave_path = autosave_path
        self.chapter_timeout = max(30.0, float(chapter_timeout))

        self.app_config = AppConfig()
        self.tts_factory = TTSFactory()
        self.results: List[BenchmarkResult] = []

        # Diretorio temporario para outputs
        self.temp_dir: Optional[Path] = None

    def _log(self, msg: str) -> None:
        """Log message."""
        print(msg)

    def _read_chapters(self) -> List[Tuple[str, str]]:
        """Le os capitulos do livro e retorna lista de (titulo, texto)."""
        reader = EbookReader(self.book_path)
        chapters = reader.get_chapters()

        result = []
        for ch in chapters:
            title = getattr(ch, "title", "") or f"Chapter {len(result) + 1}"
            text = getattr(ch, "speech_text", None) or getattr(ch, "text", "") or ""
            if text.strip():
                result.append((title, text))
            if len(result) >= self.num_chapters:
                break

        return result

    def _apply_config_to_env(self, config: BenchmarkConfig) -> None:
        """Aplica configuracao via variaveis de ambiente."""
        edge_keys = [
            "EDGE_CHUNK_CHARS",
            "EDGE_MAX_CONCURRENCY",
            "EDGE_MAX_SEGMENT_SECONDS",
            "EDGE_ENABLE_PARALLEL",
            "EDGE_BATCH_DELAY_MS",
        ]
        coqui_keys = [
            "COQUI_CHUNK_CHARS",
            "COQUI_MAX_WORKERS",
            "COQUI_SAFE_MODE",
        ]
        piper_keys = [
            "PIPER_MAX_PROCS",
        ]

        def clear_keys(keys: List[str]) -> None:
            for key in keys:
                os.environ.pop(key, None)

        if self.engine == "edge":
            clear_keys(coqui_keys)
            clear_keys(piper_keys)
            os.environ["EDGE_CHUNK_CHARS"] = str(config.chunk_chars)
            os.environ["EDGE_MAX_CONCURRENCY"] = str(config.concurrency)
            os.environ["EDGE_MAX_SEGMENT_SECONDS"] = str(config.max_segment_seconds)
            os.environ["EDGE_ENABLE_PARALLEL"] = "true" if config.enable_parallel else "false"
            os.environ["EDGE_BATCH_DELAY_MS"] = str(config.batch_delay_ms)
            reset_adaptive_settings()
        elif self.engine == "coqui":
            clear_keys(edge_keys)
            clear_keys(piper_keys)
            os.environ["COQUI_CHUNK_CHARS"] = str(config.chunk_chars)
            os.environ["COQUI_MAX_WORKERS"] = str(config.concurrency)
            if config.safe_mode is None:
                os.environ.pop("COQUI_SAFE_MODE", None)
            else:
                os.environ["COQUI_SAFE_MODE"] = "true" if config.safe_mode else "false"
        elif self.engine == "piper":
            clear_keys(edge_keys)
            clear_keys(coqui_keys)
            os.environ["PIPER_MAX_PROCS"] = str(config.concurrency)
        else:
            clear_keys(edge_keys + coqui_keys + piper_keys)

    def _create_engine(self, config: BenchmarkConfig):
        """Cria engine TTS com configuracao especifica."""
        voice = self.voice or self.app_config.voice_configs.get_voice(self.engine)

        if self.engine == "edge":
            from python_app.src.tts.edge_engine import EdgeTTSEngine

            engine = EdgeTTSEngine(
                voice=voice,
                verbose=self.verbose,
                chunk_char_limit=config.chunk_chars,
                enable_parallel=config.enable_parallel,
                max_segment_seconds=float(config.max_segment_seconds),
            )
            # Keep benchmarks deterministic: disable auto-tuning during runs.
            if hasattr(engine, "_auto_tune_enabled"):
                engine._auto_tune_enabled = False
            return engine
        else:
            # Para outras engines, usa factory
            conv_config_kwargs: Dict[str, Any] = {
                "engine": self.engine,
                "voice": voice,
            }
            if self.engine == "coqui":
                conv_config_kwargs.update(
                    coqui_chunk_chars=config.chunk_chars,
                    coqui_max_workers=config.concurrency,
                    coqui_safe_mode=config.safe_mode,
                )
            elif self.engine == "piper":
                conv_config_kwargs.update(
                    piper_max_procs=config.concurrency,
                )
            else:
                conv_config_kwargs.update(
                    edge_chunk_chars=config.chunk_chars,
                    edge_max_segment_seconds=config.max_segment_seconds,
                    edge_enable_parallel=config.enable_parallel,
                )

            conv_config = self.app_config.create_conversion_config(**conv_config_kwargs)
            return self.tts_factory.create_engine(conv_config)

    async def _run_single_benchmark(
        self,
        config: BenchmarkConfig,
        chapters: List[Tuple[str, str]],
    ) -> BenchmarkResult:
        """Executa benchmark com uma configuracao especifica."""

        self._log(f"\n{'=' * 60}")
        self._log(f"Testando: {config.name}")
        self._log(f"Descricao: {config.description}")
        if self.engine == "edge":
            self._log(
                "Parametros: "
                f"chunk={config.chunk_chars}, conc={config.concurrency}, parallel={config.enable_parallel}"
            )
        elif self.engine == "coqui":
            safe_mode = "auto" if config.safe_mode is None else str(config.safe_mode).lower()
            self._log(
                "Parametros: "
                f"chunk={config.chunk_chars}, workers={config.concurrency}, safe_mode={safe_mode}"
            )
        elif self.engine == "piper":
            self._log(f"Parametros: procs={config.concurrency}")
        else:
            self._log(f"Parametros: conc={config.concurrency}")
        self._log(f"{'=' * 60}")

        # Aplica configuracao
        self._apply_config_to_env(config)

        # Cria engine
        try:
            engine = self._create_engine(config)
        except Exception as e:
            self._log(f"   ERRO ao criar engine: {e}")
            return BenchmarkResult(
                config=config,
                chapters_converted=0,
                total_chars=0,
                total_time=0.0,
                chars_per_second=0.0,
                success_rate=0.0,
                errors=[str(e)],
            )

        # Prepara diretorio de saida
        output_dir = self.temp_dir / config.name
        output_dir.mkdir(parents=True, exist_ok=True)

        # Converte capitulos
        total_chars = 0
        converted = 0
        errors = []
        chapter_times = []

        start_time = time.time()

        for i, (title, text) in enumerate(chapters):
            chapter_num = i + 1
            if self.engine == "edge":
                ext = "mp3"
            else:
                ext = "wav"
            output_path = output_dir / f"chapter_{chapter_num:03d}.{ext}"

            char_count = len(text)
            total_chars += char_count

            self._log(
                f"   Cap {chapter_num}/{len(chapters)}: {char_count} chars... ",
            )

            chapter_start = time.time()

            try:
                result = await asyncio.wait_for(
                    engine.synthesize_async(
                        text,
                        output_path,
                    ),
                    timeout=self.chapter_timeout,
                )

                chapter_time = time.time() - chapter_start
                chapter_times.append(chapter_time)

                if result and output_path.exists():
                    converted += 1
                    speed = char_count / chapter_time if chapter_time > 0 else 0
                    self._log(f"OK ({chapter_time:.1f}s, {speed:.0f} chars/s)")
                else:
                    error_msg = getattr(engine, "last_error", "unknown")
                    errors.append(f"Cap {chapter_num}: {error_msg}")
                    self._log(f"FALHOU: {error_msg}")

            except asyncio.TimeoutError:
                chapter_time = time.time() - chapter_start
                chapter_times.append(chapter_time)
                msg = f"timeout apos {int(self.chapter_timeout)}s"
                errors.append(f"Cap {chapter_num}: {msg}")
                self._log(f"TIMEOUT: {msg}")
            except Exception as e:
                chapter_time = time.time() - chapter_start
                chapter_times.append(chapter_time)
                errors.append(f"Cap {chapter_num}: {e}")
                self._log(f"ERRO: {e}")

        total_time = time.time() - start_time
        success_rate = converted / len(chapters) if chapters else 0
        if converted == 0:
            chars_per_second = 0.0
        else:
            chars_per_second = total_chars / total_time if total_time > 0 else 0.0

        result = BenchmarkResult(
            config=config,
            chapters_converted=converted,
            total_chars=total_chars,
            total_time=total_time,
            chars_per_second=chars_per_second,
            success_rate=success_rate,
            errors=errors,
            chapter_times=chapter_times,
        )

        self._log(f"\n   Resultado: {converted}/{len(chapters)} capitulos")
        self._log(f"   Tempo total: {total_time:.1f}s")
        self._log(f"   Velocidade: {chars_per_second:.0f} chars/s")

        return result

    async def run_benchmarks(
        self,
        configs: Optional[List[BenchmarkConfig]] = None,
    ) -> List[BenchmarkResult]:
        """Executa todos os benchmarks."""

        if configs is None:
            configs = get_preset_configs("full", self.engine)

        # Cria diretorio temporario
        self.temp_dir = Path(tempfile.mkdtemp(prefix="tts_benchmark_"))

        try:
            # Le capitulos
            self._log(f"\nLendo livro: {self.book_path}")
            chapters = self._read_chapters()

            if not chapters:
                self._log("ERRO: Nenhum capitulo encontrado")
                return []

            self._log(f"Capitulos encontrados: {len(chapters)}")
            total_chars = sum(len(text) for _, text in chapters)
            self._log(f"Total de caracteres: {total_chars:,}")

            # Executa benchmarks
            self._log(f"\nExecutando {len(configs)} benchmarks...")

            for config in configs:
                result = await self._run_single_benchmark(config, chapters)
                self.results.append(result)
                if self.autosave_path:
                    self.save_results(self.autosave_path)

                # Pequena pausa entre testes para evitar rate limiting
                await asyncio.sleep(2)

        finally:
            # Limpa diretorio temporario
            if self.temp_dir and self.temp_dir.exists():
                shutil.rmtree(self.temp_dir, ignore_errors=True)

        return self.results

    def print_summary(self) -> None:
        """Imprime resumo dos resultados."""

        if not self.results:
            self._log("\nNenhum resultado para exibir")
            return

        self._log("\n" + "=" * 80)
        self._log("RESUMO DOS BENCHMARKS")
        self._log("=" * 80)

        # Ordena por velocidade
        sorted_results = sorted(
            self.results,
            key=lambda r: r.chars_per_second,
            reverse=True,
        )

        # Tabela de resultados
        self._log(
            f"\n{'Config':<25} {'Chars/s':>10} {'Tempo':>10} {'Sucesso':>10} {'Detalhes':<30}"
        )
        self._log("-" * 90)

        baseline_speed = None
        baseline_names = {
            "edge": "baseline",
            "coqui": "coqui_baseline",
            "piper": "piper_baseline",
        }
        baseline_name = baseline_names.get(self.engine, "baseline")
        for r in sorted_results:
            if r.config.name == baseline_name:
                baseline_speed = r.chars_per_second
                break

        for i, r in enumerate(sorted_results):
            speedup = ""
            if baseline_speed and baseline_speed > 0 and r.config.name != baseline_name:
                speedup_factor = r.chars_per_second / baseline_speed
                speedup = f" ({speedup_factor:.1f}x)"

            self._log(
                f"{r.config.name:<25} "
                f"{r.chars_per_second:>10.0f} "
                f"{r.total_time:>9.1f}s "
                f"{r.success_rate * 100:>9.0f}% "
                f"{r.config.description[:30]}{speedup}"
            )

        # Melhor configuracao
        if sorted_results:
            best = sorted_results[0]
            self._log(f"\n{'=' * 80}")
            self._log(f"MELHOR CONFIGURACAO: {best.config.name}")
            self._log(f"  - Velocidade: {best.chars_per_second:.0f} chars/s")
            if self.engine == "edge":
                self._log(f"  - Chunk: {best.config.chunk_chars}")
                self._log(f"  - Concurrency: {best.config.concurrency}")
                self._log(f"  - Parallel: {best.config.enable_parallel}")
            elif self.engine == "coqui":
                self._log(f"  - Chunk: {best.config.chunk_chars}")
                self._log(f"  - Workers: {best.config.concurrency}")
                safe_mode = (
                    "auto" if best.config.safe_mode is None else str(best.config.safe_mode).lower()
                )
                self._log(f"  - Safe mode: {safe_mode}")
            elif self.engine == "piper":
                self._log(f"  - Processos: {best.config.concurrency}")

            if baseline_speed and baseline_speed > 0:
                speedup = best.chars_per_second / baseline_speed
                self._log(f"  - Speedup vs baseline: {speedup:.1f}x")

        self._log("=" * 80)

    def save_results(self, output_path: Path) -> None:
        """Salva resultados em JSON."""

        data = {
            "book": str(self.book_path),
            "engine": self.engine,
            "num_chapters": self.num_chapters,
            "results": [r.to_dict() for r in self.results],
        }

        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

        self._log(f"\nResultados salvos em: {output_path}")


def get_preset_configs(preset: str, engine: str) -> List[BenchmarkConfig]:
    """Retorna configuracoes baseadas em preset."""

    engine = (engine or "edge").lower()

    if engine == "coqui":
        presets = {
            "quick": [COQUI_BASELINE_CONFIG, COQUI_OPTIMIZED_CONFIGS[1]],
            "chunks": [COQUI_BASELINE_CONFIG] + COQUI_CHUNK_CONFIGS,
            "concurrency": [COQUI_BASELINE_CONFIG] + COQUI_WORKER_CONFIGS,
            "parallel": [COQUI_BASELINE_CONFIG] + COQUI_WORKER_CONFIGS,
            "optimized": [COQUI_BASELINE_CONFIG] + COQUI_OPTIMIZED_CONFIGS,
            "full": COQUI_ALL_CONFIGS,
        }
        return presets.get(preset, COQUI_ALL_CONFIGS)

    if engine == "piper":
        presets = {
            "quick": [PIPER_BASELINE_CONFIG, PIPER_OPTIMIZED_CONFIGS[0]],
            "chunks": [PIPER_BASELINE_CONFIG] + PIPER_PROCS_CONFIGS,
            "concurrency": [PIPER_BASELINE_CONFIG] + PIPER_PROCS_CONFIGS,
            "parallel": [PIPER_BASELINE_CONFIG] + PIPER_PROCS_CONFIGS,
            "optimized": [PIPER_BASELINE_CONFIG] + PIPER_OPTIMIZED_CONFIGS,
            "full": PIPER_ALL_CONFIGS,
        }
        return presets.get(preset, PIPER_ALL_CONFIGS)

    if engine == "edge" and preset == "exhaustive":
        return build_edge_exhaustive_configs()

    presets = {
        "quick": [BASELINE_CONFIG, OPTIMIZED_CONFIGS[2]],  # baseline + aggressive
        "chunks": [BASELINE_CONFIG] + CHUNK_CONFIGS,
        "concurrency": [BASELINE_CONFIG] + CONCURRENCY_CONFIGS,
        "parallel": [BASELINE_CONFIG] + PARALLEL_CONFIGS,
        "optimized": [BASELINE_CONFIG] + OPTIMIZED_CONFIGS,
        "full": ALL_CONFIGS,
    }

    return presets.get(preset, ALL_CONFIGS)


def main():
    """Entry point."""

    parser = argparse.ArgumentParser(
        description="Benchmark de conversao TTS com diferentes configuracoes"
    )
    parser.add_argument(
        "book",
        type=Path,
        help="Caminho para o arquivo EPUB/PDF",
    )
    parser.add_argument(
        "--engine",
        "-e",
        default="edge",
        choices=["edge", "coqui", "piper"],
        help="Engine TTS (default: edge)",
    )
    parser.add_argument(
        "--chapters",
        "-c",
        type=int,
        default=10,
        help="Numero de capitulos para testar (default: 10)",
    )
    parser.add_argument(
        "--voice",
        "-v",
        help="Voz/modelo a usar (default: auto)",
    )
    parser.add_argument(
        "--preset",
        "-p",
        default="optimized",
        choices=["quick", "chunks", "concurrency", "parallel", "optimized", "full", "exhaustive"],
        help="Preset de testes (default: optimized)",
    )
    parser.add_argument(
        "--config-start",
        type=int,
        default=0,
        help="Indice inicial da lista de configs (default: 0)",
    )
    parser.add_argument(
        "--config-limit",
        type=int,
        default=0,
        help="Numero maximo de configs a executar (0 = todas)",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        help="Arquivo JSON para salvar resultados",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Modo verbose",
    )
    parser.add_argument(
        "--chapter-timeout",
        type=float,
        default=300.0,
        help="Timeout por capitulo (s) para abortar testes travados (min 30s)",
    )

    args = parser.parse_args()

    # Valida arquivo de entrada
    if not args.book.exists():
        print(f"ERRO: Arquivo nao encontrado: {args.book}")
        sys.exit(1)

    # Seleciona configuracoes
    configs = get_preset_configs(args.preset, args.engine)
    if args.config_start > 0:
        configs = configs[args.config_start :]
    if args.config_limit and args.config_limit > 0:
        configs = configs[: args.config_limit]

    print(f"\n{'=' * 60}")
    print("BENCHMARK DE CONVERSAO TTS")
    print(f"{'=' * 60}")
    print(f"Livro: {args.book}")
    print(f"Engine: {args.engine}")
    print(f"Capitulos: {args.chapters}")
    print(f"Preset: {args.preset} ({len(configs)} configuracoes)")
    if args.config_start or args.config_limit:
        print(f"Slice: start={args.config_start}, limit={args.config_limit or 'all'}")
    print(f"{'=' * 60}")

    # Resolve output path
    if args.output:
        output_path = args.output
    else:
        output_path = args.book.parent / f"benchmark_{args.book.stem}_{args.preset}.json"

    # Executa benchmark
    benchmark = ConversionBenchmark(
        book_path=args.book,
        engine=args.engine,
        num_chapters=args.chapters,
        voice=args.voice,
        verbose=args.verbose,
        autosave_path=output_path,
        chapter_timeout=args.chapter_timeout,
    )

    # Executa async
    asyncio.run(benchmark.run_benchmarks(configs))

    # Mostra resumo
    benchmark.print_summary()

    # Salva resultados
    benchmark.save_results(output_path)


if __name__ == "__main__":
    main()
