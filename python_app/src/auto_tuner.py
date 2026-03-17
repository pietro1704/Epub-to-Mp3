#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Auto-tuner based on hardware and network conditions.

Automatically configures optimization flags:
- EDGE_MAX_CONCURRENCY
- EDGE_CHUNK_CHARS
- EDGE_SAFE_CHAPTER_PARALLEL
- COQUI_MAX_WORKERS
- KOKORO_MAX_WORKERS
etc.
"""

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional

from python_app.src.hardware_monitor import HardwareSpecs, NetworkStats, SystemMonitor
from python_app.src.paths import TELEMETRY_DIR


@dataclass
class TuningProfile:
    """Optimized configuration profile."""

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
    """Performance auto-tuner."""

    # Pre-configured profiles
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
        self._profile_cache_path = Path(
            os.getenv("AUTO_TUNE_CACHE_FILE", str(TELEMETRY_DIR / "auto_tune_profile.json"))
        )
        self._cache_ttl_seconds = max(
            0, int(os.getenv("AUTO_TUNE_CACHE_TTL_SECONDS", str(6 * 60 * 60)))
        )
        self._use_cache = os.getenv("AUTO_TUNE_USE_CACHE", "1").strip().lower() not in {
            "0",
            "false",
            "no",
            "off",
        }

    @staticmethod
    def _profile_from_payload(payload: Dict[str, object]) -> Optional[TuningProfile]:
        """Build profile from persisted payload."""
        required = {
            "name",
            "description",
            "edge_max_concurrency",
            "edge_chunk_chars",
            "edge_safe_chapter_parallel",
            "edge_max_segment_seconds",
            "coqui_max_workers",
            "coqui_chunk_chars",
            "kokoro_max_workers",
            "kokoro_chunk_chars",
            "spark_max_workers",
            "spark_chunk_chars",
            "piper_max_workers",
        }
        if not required.issubset(payload):
            return None
        try:
            return TuningProfile(
                name=str(payload["name"]),
                description=str(payload["description"]),
                edge_max_concurrency=int(payload["edge_max_concurrency"]),
                edge_chunk_chars=int(payload["edge_chunk_chars"]),
                edge_safe_chapter_parallel=int(payload["edge_safe_chapter_parallel"]),
                edge_max_segment_seconds=float(payload["edge_max_segment_seconds"]),
                coqui_max_workers=int(payload["coqui_max_workers"]),
                coqui_chunk_chars=int(payload["coqui_chunk_chars"]),
                kokoro_max_workers=int(payload["kokoro_max_workers"]),
                kokoro_chunk_chars=int(payload["kokoro_chunk_chars"]),
                spark_max_workers=int(payload["spark_max_workers"]),
                spark_chunk_chars=int(payload["spark_chunk_chars"]),
                piper_max_workers=int(payload["piper_max_workers"]),
            )
        except (TypeError, ValueError):
            return None

    def _load_cached_profile(self) -> Optional[TuningProfile]:
        """Load cached profile when valid and fresh."""
        if not self._use_cache or self._cache_ttl_seconds <= 0:
            return None
        try:
            if not self._profile_cache_path.exists():
                return None
            with self._profile_cache_path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
            created_at = float(payload.get("created_at", 0.0))
            if created_at <= 0:
                return None
            if (time.time() - created_at) > self._cache_ttl_seconds:
                return None
            profile_data = payload.get("profile")
            if not isinstance(profile_data, dict):
                return None
            return self._profile_from_payload(profile_data)
        except Exception:
            return None

    def _save_cached_profile(self, profile: TuningProfile) -> None:
        """Persist latest tuned profile for future runs."""
        if not self._use_cache:
            return
        try:
            self._profile_cache_path.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "created_at": time.time(),
                "profile": {
                    "name": profile.name,
                    "description": profile.description,
                    "edge_max_concurrency": profile.edge_max_concurrency,
                    "edge_chunk_chars": profile.edge_chunk_chars,
                    "edge_safe_chapter_parallel": profile.edge_safe_chapter_parallel,
                    "edge_max_segment_seconds": profile.edge_max_segment_seconds,
                    "coqui_max_workers": profile.coqui_max_workers,
                    "coqui_chunk_chars": profile.coqui_chunk_chars,
                    "kokoro_max_workers": profile.kokoro_max_workers,
                    "kokoro_chunk_chars": profile.kokoro_chunk_chars,
                    "spark_max_workers": profile.spark_max_workers,
                    "spark_chunk_chars": profile.spark_chunk_chars,
                    "piper_max_workers": profile.piper_max_workers,
                },
            }
            with self._profile_cache_path.open("w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, indent=2)
        except Exception:
            # Non-fatal: cache write failure should never block conversion.
            return

    def select_profile(
        self, hw: HardwareSpecs, network: Optional[NetworkStats] = None
    ) -> TuningProfile:
        """
        Select the best-fit tuning profile based on hardware and network.

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
            score += 2  # Assume medium if not measured

        # Select profile based on score
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

        # Fine-tuning based on specific characteristics
        profile = self._adjust_profile(profile, hw, network)

        return profile

    def _adjust_profile(
        self, profile: TuningProfile, hw: HardwareSpecs, network: Optional[NetworkStats]
    ) -> TuningProfile:
        """Adjust profile based on specific hardware/network characteristics."""
        # Create modified copy
        from copy import deepcopy

        adjusted = deepcopy(profile)

        # Reduce workers if RAM is low
        if hw.ram_available_gb < 4:
            adjusted.edge_safe_chapter_parallel = max(1, adjusted.edge_safe_chapter_parallel // 2)
            adjusted.coqui_max_workers = max(1, adjusted.coqui_max_workers // 2)

        # Increase workers if GPU is available
        if hw.gpu_available and hw.gpu_type == "cuda":
            adjusted.coqui_max_workers = min(6, adjusted.coqui_max_workers + 1)
            adjusted.kokoro_max_workers = min(6, adjusted.kokoro_max_workers + 1)

        # Reduce concurrency for slow networks
        if network and network.tier == "slow":
            adjusted.edge_max_concurrency = max(2, adjusted.edge_max_concurrency // 2)
            adjusted.edge_chunk_chars = max(3000, adjusted.edge_chunk_chars // 2)

        # Increase concurrency for ultra-fast networks
        if network and network.tier == "ultra":
            adjusted.edge_max_concurrency = min(16, int(adjusted.edge_max_concurrency * 1.5))

        return adjusted

    def apply_profile(self, profile: TuningProfile, force: bool = False) -> None:
        """
        Apply profile by setting environment variables.

        Args:
            profile: Profile to apply
            force: If True, overwrite already-set vars
        """

        def set_if_not_exists(key: str, value: str) -> bool:
            """Set env var if not already set, or always if force=True."""
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
        # Piper runtime uses PIPER_MAX_PROCS; keep both for compatibility.
        set_if_not_exists("PIPER_MAX_PROCS", str(profile.piper_max_workers))

        self._applied_profile = profile

        if self.verbose:
            self._print_applied_profile(profile)

    def _print_applied_profile(self, profile: TuningProfile) -> None:
        """Print applied performance profile summary."""
        print("=" * 70)
        print(f"🎯 AUTO-CONFIGURED PERFORMANCE PROFILE: {profile.name.upper()}")
        print("=" * 70)
        print(f"Description: {profile.description}\n")
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
            Applied profile
        """
        if not force:
            cached_profile = self._load_cached_profile()
            if cached_profile is not None:
                self.apply_profile(cached_profile, force=False)
                if self.verbose:
                    print(f"⚡ Auto-tuning: loaded cached profile from {self._profile_cache_path}")
                return cached_profile

        # Detecta hardware
        hw = self.monitor.detect_hardware()

        # Mede rede (opcional)
        network = None
        if measure_network:
            network = await self.monitor.classify_network()

        # Select optimized profile
        profile = self.select_profile(hw, network)

        # Apply settings
        self.apply_profile(profile, force=force)
        self._save_cached_profile(profile)

        return profile

    def get_applied_profile(self) -> Optional[TuningProfile]:
        """Return the currently applied profile."""
        return self._applied_profile
