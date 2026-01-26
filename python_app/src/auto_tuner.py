#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Auto-tuner de performance baseado em hardware e rede.

Configura automaticamente flags de otimização:
- EDGE_MAX_CONCURRENCY
- EDGE_CHUNK_CHARS
- EDGE_SAFE_CHAPTER_PARALLEL
- COQUI_MAX_WORKERS
- KOKORO_MAX_WORKERS
etc.
"""

import os
from dataclasses import dataclass
from typing import Dict, Optional

from python_app.src.hardware_monitor import HardwareSpecs, NetworkStats, SystemMonitor


@dataclass
class TuningProfile:
    """Perfil de configuração otimizada."""

    name: str
    description: str

    # Edge-TTS
    edge_max_concurrency: int
    edge_chunk_chars: int
    edge_safe_chapter_parallel: int
    edge_max_segment_seconds: float

    # Coqui TTS
    coqui_max_workers: int
    coqui_chunk_chars: int

    # Kokoro TTS
    kokoro_max_workers: int
    kokoro_chunk_chars: int

    # Spark TTS
    spark_max_workers: int
    spark_chunk_chars: int

    # Piper TTS
    piper_max_workers: int


class AutoTuner:
    """Auto-tuner de performance."""

    # Perfis pré-configurados
    PROFILES: Dict[str, TuningProfile] = {
        "conservative": TuningProfile(
            name="Conservative",
            description="Conexão lenta ou hardware limitado (seguro)",
            edge_max_concurrency=2,
            edge_chunk_chars=4000,
            edge_safe_chapter_parallel=1,
            edge_max_segment_seconds=120.0,
            coqui_max_workers=1,
            coqui_chunk_chars=1000,
            kokoro_max_workers=1,
            kokoro_chunk_chars=1500,
            spark_max_workers=1,
            spark_chunk_chars=1000,
            piper_max_workers=2,
        ),
        "balanced": TuningProfile(
            name="Balanced",
            description="Conexão média e hardware moderado",
            edge_max_concurrency=4,
            edge_chunk_chars=8000,
            edge_safe_chapter_parallel=2,
            edge_max_segment_seconds=85.0,
            coqui_max_workers=2,
            coqui_chunk_chars=1500,
            kokoro_max_workers=2,
            kokoro_chunk_chars=2000,
            spark_max_workers=1,
            spark_chunk_chars=1500,
            piper_max_workers=4,
        ),
        "performance": TuningProfile(
            name="Performance",
            description="Boa conexão e hardware potente",
            edge_max_concurrency=8,
            edge_chunk_chars=10000,
            edge_safe_chapter_parallel=4,
            edge_max_segment_seconds=85.0,
            coqui_max_workers=3,
            coqui_chunk_chars=2000,
            kokoro_max_workers=3,
            kokoro_chunk_chars=2500,
            spark_max_workers=2,
            spark_chunk_chars=1500,
            piper_max_workers=6,
        ),
        "maximum": TuningProfile(
            name="Maximum",
            description="Conexão ultra-rápida e hardware top de linha",
            edge_max_concurrency=12,
            edge_chunk_chars=12000,
            edge_safe_chapter_parallel=6,
            edge_max_segment_seconds=85.0,
            coqui_max_workers=4,
            coqui_chunk_chars=2500,
            kokoro_max_workers=4,
            kokoro_chunk_chars=3000,
            spark_max_workers=2,
            spark_chunk_chars=2000,
            piper_max_workers=8,
        ),
    }

    def __init__(self, verbose: bool = True):
        self.verbose = verbose
        self.monitor = SystemMonitor(verbose=verbose)
        self._applied_profile: Optional[TuningProfile] = None

    def select_profile(
        self, hw: HardwareSpecs, network: Optional[NetworkStats] = None
    ) -> TuningProfile:
        """
        Seleciona perfil otimizado baseado em hardware e rede.

        Lógica:
        - Conservative: CPU < 4 cores OR RAM < 8GB OR network slow
        - Balanced: CPU 4-8 cores AND RAM 8-16GB AND network medium
        - Performance: CPU > 8 cores OR RAM > 16GB OR network fast
        - Maximum: CPU > 12 cores AND RAM > 24GB AND network ultra + GPU
        """
        score = 0

        # CPU score (0-4)
        if hw.cpu_physical_cores >= 16:
            score += 4
        elif hw.cpu_physical_cores >= 12:
            score += 3
        elif hw.cpu_physical_cores >= 8:
            score += 2
        elif hw.cpu_physical_cores >= 4:
            score += 1

        # RAM score (0-4)
        if hw.ram_total_gb >= 32:
            score += 4
        elif hw.ram_total_gb >= 16:
            score += 3
        elif hw.ram_total_gb >= 8:
            score += 2
        else:
            score += 1

        # GPU score (0-2)
        if hw.gpu_available:
            if hw.gpu_type == "cuda":
                score += 2
            else:
                score += 1

        # Storage score (0-1)
        if hw.storage_type == "ssd":
            score += 1

        # Network score (0-4)
        if network:
            if network.tier == "ultra":
                score += 4
            elif network.tier == "fast":
                score += 3
            elif network.tier == "medium":
                score += 2
            else:
                score += 1
        else:
            score += 2  # Assume médio se não medido

        # Seleciona perfil baseado em score
        # 0-4: conservative
        # 5-9: balanced
        # 10-13: performance
        # 14+: maximum
        if score >= 14:
            profile = self.PROFILES["maximum"]
        elif score >= 10:
            profile = self.PROFILES["performance"]
        elif score >= 5:
            profile = self.PROFILES["balanced"]
        else:
            profile = self.PROFILES["conservative"]

        # Ajustes finos baseados em características específicas
        profile = self._adjust_profile(profile, hw, network)

        return profile

    def _adjust_profile(
        self, profile: TuningProfile, hw: HardwareSpecs, network: Optional[NetworkStats]
    ) -> TuningProfile:
        """Ajusta perfil baseado em características específicas."""
        # Cria cópia modificada
        from copy import deepcopy

        adjusted = deepcopy(profile)

        # Reduz workers se RAM baixa
        if hw.ram_available_gb < 4:
            adjusted.edge_safe_chapter_parallel = max(1, adjusted.edge_safe_chapter_parallel // 2)
            adjusted.coqui_max_workers = max(1, adjusted.coqui_max_workers // 2)

        # Aumenta workers se GPU disponível
        if hw.gpu_available and hw.gpu_type == "cuda":
            adjusted.coqui_max_workers = min(6, adjusted.coqui_max_workers + 1)
            adjusted.kokoro_max_workers = min(6, adjusted.kokoro_max_workers + 1)

        # Reduz concurrency se rede lenta
        if network and network.tier == "slow":
            adjusted.edge_max_concurrency = max(2, adjusted.edge_max_concurrency // 2)
            adjusted.edge_chunk_chars = max(3000, adjusted.edge_chunk_chars // 2)

        # Aumenta concurrency se rede ultra
        if network and network.tier == "ultra":
            adjusted.edge_max_concurrency = min(16, int(adjusted.edge_max_concurrency * 1.5))

        return adjusted

    def apply_profile(self, profile: TuningProfile, force: bool = False) -> None:
        """
        Aplica perfil setando variáveis de ambiente.

        Args:
            profile: Perfil a aplicar
            force: Se True, sobrescreve vars já setadas
        """

        def set_if_not_exists(key: str, value: str) -> bool:
            """Seta env var se não existir ou se force=True."""
            if force or key not in os.environ:
                os.environ[key] = value
                return True
            return False

        # Edge-TTS
        set_if_not_exists("EDGE_MAX_CONCURRENCY", str(profile.edge_max_concurrency))
        set_if_not_exists("EDGE_CHUNK_CHARS", str(profile.edge_chunk_chars))
        set_if_not_exists("EDGE_SAFE_CHAPTER_PARALLEL", str(profile.edge_safe_chapter_parallel))
        set_if_not_exists("EDGE_MAX_SEGMENT_SECONDS", str(profile.edge_max_segment_seconds))

        # Coqui TTS
        set_if_not_exists("COQUI_MAX_WORKERS", str(profile.coqui_max_workers))
        set_if_not_exists("COQUI_CHUNK_CHARS", str(profile.coqui_chunk_chars))

        # Kokoro TTS
        set_if_not_exists("KOKORO_MAX_WORKERS", str(profile.kokoro_max_workers))
        set_if_not_exists("KOKORO_CHUNK_CHARS", str(profile.kokoro_chunk_chars))

        # Spark TTS
        set_if_not_exists("SPARK_MAX_WORKERS", str(profile.spark_max_workers))
        set_if_not_exists("SPARK_CHUNK_CHARS", str(profile.spark_chunk_chars))

        # Piper TTS
        set_if_not_exists("PIPER_MAX_WORKERS", str(profile.piper_max_workers))

        self._applied_profile = profile

        if self.verbose:
            self._print_applied_profile(profile)

    def _print_applied_profile(self, profile: TuningProfile) -> None:
        """Imprime perfil aplicado."""
        print("=" * 70)
        print(f"🎯 PERFIL DE PERFORMANCE AUTO-CONFIGURADO: {profile.name.upper()}")
        print("=" * 70)
        print(f"Descrição: {profile.description}\n")
        print("Edge-TTS:")
        print(f"  EDGE_MAX_CONCURRENCY: {profile.edge_max_concurrency}")
        print(f"  EDGE_CHUNK_CHARS: {profile.edge_chunk_chars}")
        print(f"  EDGE_SAFE_CHAPTER_PARALLEL: {profile.edge_safe_chapter_parallel}")
        print(f"  EDGE_MAX_SEGMENT_SECONDS: {profile.edge_max_segment_seconds}")
        print("\nCoqui TTS:")
        print(f"  COQUI_MAX_WORKERS: {profile.coqui_max_workers}")
        print(f"  COQUI_CHUNK_CHARS: {profile.coqui_chunk_chars}")
        print("\nKokoro TTS:")
        print(f"  KOKORO_MAX_WORKERS: {profile.kokoro_max_workers}")
        print(f"  KOKORO_CHUNK_CHARS: {profile.kokoro_chunk_chars}")
        print("=" * 70 + "\n")

    async def auto_configure(
        self, force: bool = False, measure_network: bool = True
    ) -> TuningProfile:
        """
        Detecta hardware/rede e configura automaticamente.

        Args:
            force: Sobrescreve configurações existentes
            measure_network: Se True, mede velocidade de rede (adiciona ~3s)

        Returns:
            Perfil aplicado
        """
        # Detecta hardware
        hw = self.monitor.detect_hardware()

        # Mede rede (opcional)
        network = None
        if measure_network:
            network = await self.monitor.classify_network()

        # Seleciona perfil otimizado
        profile = self.select_profile(hw, network)

        # Aplica configurações
        self.apply_profile(profile, force=force)

        return profile

    def get_applied_profile(self) -> Optional[TuningProfile]:
        """Retorna perfil aplicado atualmente."""
        return self._applied_profile
