#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sistema de ajuste adaptativo de performance em tempo real.

Monitora conversão e ajusta parâmetros dinamicamente para maximizar velocidade.
"""

import time
from dataclasses import dataclass
from typing import Dict, List, Literal, Optional

from python_app.src.hardware_monitor import SystemMonitor


@dataclass
class ConversionMetrics:
    """Métricas de conversão em tempo real."""

    timestamp: float
    chars_processed: int
    chapters_completed: int
    elapsed_seconds: float
    chars_per_second: float
    chapters_per_minute: float
    current_concurrency: int
    current_chunk_size: int
    errors_count: int
    throttle_events: int
    cpu_percent: float
    memory_percent: float
    network_latency_ms: float


@dataclass
class PerformanceAdjustment:
    """Ajuste de performance a ser aplicado."""

    action: Literal[
        "increase_concurrency",
        "decrease_concurrency",
        "increase_chunk",
        "decrease_chunk",
        "no_change",
    ]
    reason: str
    edge_max_concurrency: Optional[int] = None
    edge_chunk_chars: Optional[int] = None
    edge_safe_chapter_parallel: Optional[int] = None


class AdaptivePerformanceController:
    """Controlador de performance adaptativa em tempo real."""

    def __init__(self, verbose: bool = True):
        self.verbose = verbose
        self.system_monitor = SystemMonitor(verbose=False)

        # Estado inicial
        self._baseline_concurrency = 4
        self._baseline_chunk_size = 8000
        self._baseline_parallel = 2

        # Histórico de métricas
        self._metrics_history: List[ConversionMetrics] = []
        self._adjustment_history: List[PerformanceAdjustment] = []

        # Estado de conversão
        self._conversion_start_time: Optional[float] = None
        self._total_chars_processed = 0
        self._total_chapters_completed = 0
        self._total_errors = 0
        self._total_throttles = 0

        # Limites de segurança
        self._max_concurrency = 16
        self._min_concurrency = 1
        self._max_chunk_size = 15000
        self._min_chunk_size = 2000
        self._max_parallel = 8
        self._min_parallel = 1

        # Contadores para decisões
        self._consecutive_successes = 0
        self._consecutive_failures = 0
        self._last_adjustment_time = 0.0
        self._adjustment_cooldown = (
            15.0  # segundos entre ajustes (reduzido de 30 para mais responsividade)
        )
        self._fast_adjustment_threshold = (
            5  # Ajustes rápidos após 5 sucessos (antes era implícito em 10)
        )

        # Melhor configuração encontrada
        self._best_throughput = 0.0
        self._best_config = {
            "concurrency": self._baseline_concurrency,
            "chunk_size": self._baseline_chunk_size,
            "parallel": self._baseline_parallel,
        }

    def start_conversion(self):
        """Inicia monitoramento de uma nova conversão."""
        self._conversion_start_time = time.time()
        self._total_chars_processed = 0
        self._total_chapters_completed = 0
        self._total_errors = 0
        self._total_throttles = 0
        self._metrics_history.clear()
        self._adjustment_history.clear()
        self._consecutive_successes = 0
        self._consecutive_failures = 0

        if self.verbose:
            print("\n🎯 Adaptive Performance Controller iniciado")
            print(
                f"   Config inicial: concurrency={self._baseline_concurrency}, "
                f"chunk={self._baseline_chunk_size}, parallel={self._baseline_parallel}"
            )

    def record_chapter_completion(
        self,
        chars_processed: int,
        success: bool,
        error: Optional[str] = None,
        throttled: bool = False,
    ):
        """Registra conclusão de um capítulo."""
        self._total_chars_processed += chars_processed
        if success:
            self._total_chapters_completed += 1
            self._consecutive_successes += 1
            self._consecutive_failures = 0
        else:
            self._total_errors += 1
            self._consecutive_failures += 1
            self._consecutive_successes = 0

        if throttled:
            self._total_throttles += 1

        # Calcula métricas atuais
        elapsed = time.time() - (self._conversion_start_time or time.time())
        chars_per_sec = self._total_chars_processed / elapsed if elapsed > 0 else 0
        chapters_per_min = (self._total_chapters_completed / elapsed) * 60 if elapsed > 0 else 0

        # Hardware não muda durante conversão - removido detect_hardware() para performance

        metrics = ConversionMetrics(
            timestamp=time.time(),
            chars_processed=self._total_chars_processed,
            chapters_completed=self._total_chapters_completed,
            elapsed_seconds=elapsed,
            chars_per_second=chars_per_sec,
            chapters_per_minute=chapters_per_min,
            current_concurrency=self._get_current_env_int(
                "EDGE_MAX_CONCURRENCY", self._baseline_concurrency
            ),
            current_chunk_size=self._get_current_env_int(
                "EDGE_CHUNK_CHARS", self._baseline_chunk_size
            ),
            errors_count=self._total_errors,
            throttle_events=self._total_throttles,
            cpu_percent=0.0,  # Será preenchido se disponível
            memory_percent=0.0,
            network_latency_ms=0.0,
        )

        self._metrics_history.append(metrics)

        # Atualiza melhor throughput
        if chars_per_sec > self._best_throughput:
            self._best_throughput = chars_per_sec
            self._best_config = {
                "concurrency": metrics.current_concurrency,
                "chunk_size": metrics.current_chunk_size,
                "parallel": self._get_current_env_int(
                    "EDGE_SAFE_CHAPTER_PARALLEL", self._baseline_parallel
                ),
            }

    def should_adjust(self) -> bool:
        """Verifica se deve fazer ajuste agora."""
        # Precisa de pelo menos 2 capítulos para tomar decisões (reduzido de 3 para mais responsividade)
        if self._total_chapters_completed < 2:
            return False

        # Se há muitos sucessos consecutivos, permite ajuste rápido (ignorar cooldown)
        if self._consecutive_successes >= self._fast_adjustment_threshold:
            return True

        # Se há erros ou throttling, permite ajuste imediato
        if self._consecutive_failures >= 2 or self._total_throttles > 0:
            return True

        # Respeita cooldown entre ajustes normais
        time_since_last = time.time() - self._last_adjustment_time
        if time_since_last < self._adjustment_cooldown:
            return False

        return True

    def calculate_adjustment(self) -> PerformanceAdjustment:
        """Calcula ajuste necessário baseado em métricas."""
        if not self.should_adjust():
            return PerformanceAdjustment(
                action="no_change", reason="Cooldown ou dados insuficientes"
            )

        current_concurrency = self._get_current_env_int(
            "EDGE_MAX_CONCURRENCY", self._baseline_concurrency
        )
        current_chunk = self._get_current_env_int("EDGE_CHUNK_CHARS", self._baseline_chunk_size)
        self._get_current_env_int("EDGE_SAFE_CHAPTER_PARALLEL", self._baseline_parallel)

        # Análise de tendência
        recent_metrics = (
            self._metrics_history[-5:] if len(self._metrics_history) >= 5 else self._metrics_history
        )
        if len(recent_metrics) < 2:
            return PerformanceAdjustment(action="no_change", reason="Dados insuficientes")

        avg_throughput = sum(m.chars_per_second for m in recent_metrics) / len(recent_metrics)
        error_rate = self._total_errors / max(1, self._total_chapters_completed)
        throttle_rate = self._total_throttles / max(1, self._total_chapters_completed)

        # DECISÃO 1: Se muitos erros ou throttling, REDUZIR
        if error_rate > 0.2 or throttle_rate > 0.3:
            if current_concurrency > self._min_concurrency:
                return PerformanceAdjustment(
                    action="decrease_concurrency",
                    reason=f"Alta taxa de erros ({error_rate:.1%}) ou throttling ({throttle_rate:.1%})",
                    edge_max_concurrency=max(self._min_concurrency, current_concurrency - 2),
                )

        # DECISÃO 2: Se muitos throttles mas poucos erros, reduzir chunk
        if throttle_rate > 0.3 and error_rate < 0.1:
            if current_chunk > self._min_chunk_size:
                return PerformanceAdjustment(
                    action="decrease_chunk",
                    reason=f"Throttling detectado ({throttle_rate:.1%})",
                    edge_chunk_chars=max(self._min_chunk_size, current_chunk - 2000),
                )

        # DECISÃO 3: Se indo bem, tentar AUMENTAR concurrency gradualmente
        # Mais agressivo: requer menos sucessos e aumenta mais rápido
        if self._consecutive_successes >= 3 and error_rate < 0.05 and throttle_rate < 0.1:
            if current_concurrency < self._max_concurrency:
                # Aumento mais agressivo quando performance é excelente
                increment = 3 if self._consecutive_successes >= 5 else 2
                new_concurrency = min(self._max_concurrency, current_concurrency + increment)
                return PerformanceAdjustment(
                    action="increase_concurrency",
                    reason=f"Performance estável ({self._consecutive_successes} sucessos, taxa erro {error_rate:.1%})",
                    edge_max_concurrency=new_concurrency,
                )

        # DECISÃO 4: Se throughput baixo mas sem erros, aumentar chunk
        if avg_throughput < self._best_throughput * 0.7 and error_rate < 0.05:
            if current_chunk < self._max_chunk_size:
                return PerformanceAdjustment(
                    action="increase_chunk",
                    reason=f"Throughput abaixo do melhor ({avg_throughput:.0f} vs {self._best_throughput:.0f} chars/s)",
                    edge_chunk_chars=min(self._max_chunk_size, current_chunk + 2000),
                )

        # DECISÃO 5: Se performance piorou muito, voltar para melhor config
        if avg_throughput < self._best_throughput * 0.5 and self._best_throughput > 0:
            return PerformanceAdjustment(
                action="decrease_concurrency",
                reason="Performance muito abaixo do pico, voltando para melhor config",
                edge_max_concurrency=self._best_config["concurrency"],
                edge_chunk_chars=self._best_config["chunk_size"],
                edge_safe_chapter_parallel=self._best_config["parallel"],
            )

        return PerformanceAdjustment(action="no_change", reason="Performance estável")

    def apply_adjustment(self, adjustment: PerformanceAdjustment) -> bool:
        """Aplica ajuste de performance."""
        import os

        if adjustment.action == "no_change":
            return False

        self._last_adjustment_time = time.time()
        self._adjustment_history.append(adjustment)

        applied = []
        if adjustment.edge_max_concurrency is not None:
            os.environ["EDGE_MAX_CONCURRENCY"] = str(adjustment.edge_max_concurrency)
            applied.append(f"EDGE_MAX_CONCURRENCY={adjustment.edge_max_concurrency}")

        if adjustment.edge_chunk_chars is not None:
            os.environ["EDGE_CHUNK_CHARS"] = str(adjustment.edge_chunk_chars)
            applied.append(f"EDGE_CHUNK_CHARS={adjustment.edge_chunk_chars}")

        if adjustment.edge_safe_chapter_parallel is not None:
            os.environ["EDGE_SAFE_CHAPTER_PARALLEL"] = str(adjustment.edge_safe_chapter_parallel)
            applied.append(f"EDGE_SAFE_CHAPTER_PARALLEL={adjustment.edge_safe_chapter_parallel}")

        if self.verbose and applied:
            print(f"\n⚡ AJUSTE ADAPTATIVO: {adjustment.action}")
            print(f"   Razão: {adjustment.reason}")
            for change in applied:
                print(f"   • {change}")

        return True

    def get_summary(self) -> Dict:
        """Retorna sumário da conversão."""
        if not self._metrics_history:
            return {}

        latest = self._metrics_history[-1]
        return {
            "total_chars": self._total_chars_processed,
            "total_chapters": self._total_chapters_completed,
            "elapsed_seconds": latest.elapsed_seconds,
            "chars_per_second": latest.chars_per_second,
            "chapters_per_minute": latest.chapters_per_minute,
            "total_errors": self._total_errors,
            "total_throttles": self._total_throttles,
            "adjustments_made": len(self._adjustment_history),
            "best_throughput": self._best_throughput,
            "best_config": self._best_config,
            "final_config": {
                "concurrency": latest.current_concurrency,
                "chunk_size": latest.current_chunk_size,
            },
        }

    def print_summary(self):
        """Imprime sumário formatado."""
        summary = self.get_summary()
        if not summary:
            return

        print("\n" + "=" * 70)
        print("📊 SUMÁRIO DE PERFORMANCE ADAPTATIVA")
        print("=" * 70)
        print(
            f"Total processado: {summary['total_chars']:,} caracteres em {summary['total_chapters']} capítulos"
        )
        print(f"Tempo total: {summary['elapsed_seconds']:.1f}s")
        print(
            f"Throughput médio: {summary['chars_per_second']:.0f} chars/s ({summary['chapters_per_minute']:.1f} cap/min)"
        )
        print(f"Erros: {summary['total_errors']} | Throttles: {summary['total_throttles']}")
        print(f"Ajustes realizados: {summary['adjustments_made']}")
        print(f"\nMelhor throughput: {summary['best_throughput']:.0f} chars/s")
        print(
            f"Melhor config: concurrency={summary['best_config']['concurrency']}, "
            f"chunk={summary['best_config']['chunk_size']}"
        )
        print(
            f"Config final: concurrency={summary['final_config']['concurrency']}, "
            f"chunk={summary['final_config']['chunk_size']}"
        )
        print("=" * 70 + "\n")

    def _get_current_env_int(self, key: str, default: int) -> int:
        """Obtém valor atual de env var."""
        import os

        try:
            return int(os.getenv(key, str(default)))
        except (ValueError, TypeError):
            return default
