# -*- coding: utf-8 -*-
"""
Hardware detection and automatic performance optimization.

Detects CPU, RAM, GPU, and network capabilities to automatically
configure optimal conversion settings for maximum speed.
"""

from __future__ import annotations

import contextlib
import os
import platform
import socket
import statistics
import subprocess
import time
from dataclasses import dataclass
from typing import Optional

import psutil


@dataclass
class HardwareProfile:
    """System hardware profile for optimization."""

    # Fields WITHOUT defaults (must come first)
    # CPU
    cpu_count: int
    cpu_physical: int
    cpu_freq_max: float  # MHz
    cpu_brand: str

    # Memory
    ram_total_gb: float
    ram_available_gb: float

    # GPU
    has_gpu: bool

    # Network
    network_speed_estimate: str  # "slow", "medium", "fast", "ultra"

    # Platform
    os_type: str  # "Darwin", "Linux", "Windows"

    # Fields WITH defaults (must come last)
    gpu_type: Optional[str] = None
    is_macos: bool = False
    is_linux: bool = False
    is_windows: bool = False

    # Derived recommendations
    recommended_concurrency: int = 8  # Padrão mais agressivo para melhor performance
    recommended_parallel: bool = True
    recommended_chapter_parallel: int = 3  # Padrão otimizado: processar 3 capítulos simultaneamente
    performance_tier: str = "high"  # Padrão "high" para melhor performance
    ram_budget_gb: float = 0.0  # RAM amount converter is allowed to consume aggressively
    force_sequential: bool = False  # True when chapter-level parallelism would slow things down


class HardwareDetector:
    """Detect hardware capabilities and recommend optimal settings."""

    # OPTIMIZED: More aggressive network profiles for faster conversion
    _EDGE_NETWORK_PROFILES = {
        "slow": {
            "chunk_chars": 8000,  # Increased from 6k
            "max_segment_seconds": 120,  # Allow longer segments on Edge
            "concurrency_scale": 0.6,  # Increased from 0.5
            "concurrency_cap": 3,  # Increased from 2
            "edge_parallel": True,  # Changed to True
        },
        "medium": {
            "chunk_chars": 10000,  # Increased from 8k
            "max_segment_seconds": 180,  # Allow longer segments on Edge
            "concurrency_scale": 0.8,  # Increased from 0.7
            "concurrency_cap": 4,  # Increased from 3
            "edge_parallel": True,
        },
        "fast": {
            "chunk_chars": 12000,  # Increased from 10k
            "max_segment_seconds": 240,  # Allow longer segments on Edge
            "concurrency_scale": 0.9,  # Increased from 0.85
            "concurrency_cap": 6,  # Increased from 4
            "edge_parallel": True,
        },
        "ultra": {
            "chunk_chars": 15000,  # Increased from 12k
            "max_segment_seconds": 300,  # Allow longer segments on Edge
            "concurrency_scale": 1.0,
            "concurrency_cap": 8,  # Increased from 4
            "edge_parallel": True,
        },
    }

    @staticmethod
    def detect() -> HardwareProfile:
        """Detect system hardware and return optimization profile."""

        # CPU detection
        try:
            cpu_count = psutil.cpu_count(logical=True) or 4
        except Exception:
            cpu_count = 4
        try:
            cpu_physical = psutil.cpu_count(logical=False) or max(1, cpu_count // 2)
        except Exception:
            cpu_physical = max(1, cpu_count // 2)

        try:
            cpu_freq = psutil.cpu_freq()
            cpu_freq_max = cpu_freq.max if cpu_freq else 2400.0
        except Exception:
            cpu_freq_max = 2400.0

        cpu_brand = HardwareDetector._detect_cpu_brand()

        # Memory detection
        try:
            mem = psutil.virtual_memory()
            ram_total_gb = mem.total / (1024**3)
            ram_available_gb = mem.available / (1024**3)
        except Exception:
            ram_total_gb = 8.0
            ram_available_gb = 4.0

        # GPU detection
        has_gpu, gpu_type = HardwareDetector._detect_gpu()

        # Network estimation (placeholder - could be enhanced)
        network_speed = HardwareDetector._estimate_network_speed()

        # Platform
        os_type = platform.system()
        is_macos = os_type == "Darwin"
        is_linux = os_type == "Linux"
        is_windows = os_type == "Windows"

        profile = HardwareProfile(
            cpu_count=cpu_count,
            cpu_physical=cpu_physical,
            cpu_freq_max=cpu_freq_max,
            cpu_brand=cpu_brand,
            ram_total_gb=ram_total_gb,
            ram_available_gb=ram_available_gb,
            has_gpu=has_gpu,
            gpu_type=gpu_type,
            network_speed_estimate=network_speed,
            os_type=os_type,
            is_macos=is_macos,
            is_linux=is_linux,
            is_windows=is_windows,
        )

        # Calculate recommendations
        HardwareDetector._calculate_recommendations(profile)

        return profile

    @staticmethod
    def _detect_cpu_brand() -> str:
        """Detect CPU brand/model."""
        try:
            if platform.system() == "Darwin":
                # macOS
                result = subprocess.run(
                    ["sysctl", "-n", "machdep.cpu.brand_string"],
                    capture_output=True,
                    text=True,
                    timeout=2,
                )
                if result.returncode == 0:
                    return result.stdout.strip()
            elif platform.system() == "Linux":
                # Linux
                with open("/proc/cpuinfo", "r") as f:
                    for line in f:
                        if "model name" in line:
                            return line.split(":")[1].strip()
            elif platform.system() == "Windows":
                # Windows
                result = subprocess.run(
                    ["wmic", "cpu", "get", "name"], capture_output=True, text=True, timeout=2
                )
                if result.returncode == 0:
                    lines = result.stdout.strip().split("\n")
                    if len(lines) > 1:
                        return lines[1].strip()
        except Exception:
            pass

        return "Unknown CPU"

    @staticmethod
    def _detect_gpu() -> tuple[bool, Optional[str]]:
        """Detect if GPU is available and its type."""
        try:
            if platform.system() == "Darwin":
                # macOS - check for Metal GPU
                result = subprocess.run(
                    ["system_profiler", "SPDisplaysDataType"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode == 0:
                    output = result.stdout.lower()
                    # Check for dedicated GPU keywords
                    if any(keyword in output for keyword in ["nvidia", "amd", "radeon", "geforce"]):
                        # Extract GPU name
                        for line in result.stdout.split("\n"):
                            if "chipset model" in line.lower():
                                gpu_name = line.split(":")[1].strip()
                                return (True, gpu_name)
                        return (True, "Dedicated GPU")
                    elif "intel" in output:
                        # Integrated Intel GPU
                        for line in result.stdout.split("\n"):
                            if "chipset model" in line.lower():
                                gpu_name = line.split(":")[1].strip()
                                return (False, gpu_name)  # Integrated doesn't count as "has_gpu"
                        return (False, "Intel Integrated")

            elif platform.system() == "Linux":
                # Linux - check for NVIDIA/AMD
                try:
                    result = subprocess.run(["lspci"], capture_output=True, text=True, timeout=2)
                    if result.returncode == 0:
                        output = result.stdout.lower()
                        if "nvidia" in output or "geforce" in output:
                            return (True, "NVIDIA GPU")
                        elif "amd" in output or "radeon" in output:
                            return (True, "AMD GPU")
                except FileNotFoundError:
                    pass

            elif platform.system() == "Windows":
                # Windows - check via wmic
                result = subprocess.run(
                    ["wmic", "path", "win32_VideoController", "get", "name"],
                    capture_output=True,
                    text=True,
                    timeout=2,
                )
                if result.returncode == 0:
                    output = result.stdout.lower()
                    if "nvidia" in output or "geforce" in output or "quadro" in output:
                        return (True, "NVIDIA GPU")
                    elif "amd" in output or "radeon" in output:
                        return (True, "AMD GPU")
                    elif "intel" in output and ("uhd" in output or "iris" in output):
                        return (False, "Intel Integrated")

        except Exception:
            pass

        return (False, None)

    @staticmethod
    def _estimate_network_speed() -> str:
        """Estimate network speed (basic heuristic)."""
        override = os.getenv("EDGE_NETWORK_TIER", "").strip().lower()
        if override in HardwareDetector._EDGE_NETWORK_PROFILES:
            return override

        probe_toggle = os.getenv("EDGE_NETWORK_PROBE", "1").strip().lower()
        if probe_toggle in {"0", "false", "off", "no"}:
            return "fast"

        host = os.getenv("EDGE_NETWORK_HOST", "api.msedgeservices.com")
        try:
            attempts = int(os.getenv("EDGE_NETWORK_PROBE_ATTEMPTS", "3"))
        except ValueError:
            attempts = 3
        try:
            timeout = float(os.getenv("EDGE_NETWORK_PROBE_TIMEOUT", "1.2"))
        except ValueError:
            timeout = 1.2
        try:
            pause = float(os.getenv("EDGE_NETWORK_PROBE_PAUSE", "0.15"))
        except ValueError:
            pause = 0.15

        latencies_ms = []
        for _ in range(max(1, attempts)):
            start = time.perf_counter()
            try:
                sock = socket.create_connection((host, 443), timeout=timeout)
                sock.close()
                latencies_ms.append((time.perf_counter() - start) * 1000.0)
            except OSError:
                pass
            time.sleep(pause)

        if not latencies_ms:
            return "slow"

        median = statistics.median(latencies_ms)
        if median <= 30:
            return "ultra"
        if median <= 70:
            return "fast"
        if median <= 140:
            return "medium"
        return "slow"

    @staticmethod
    def _calculate_recommendations(profile: HardwareProfile) -> None:
        """Calculate optimal settings based on hardware profile."""

        # Performance tier calculation
        score = 0

        # CPU scoring (0-40 points)
        if profile.cpu_physical >= 8:
            score += 40
        elif profile.cpu_physical >= 4:
            score += 30
        elif profile.cpu_physical >= 2:
            score += 20
        else:
            score += 10

        # RAM scoring (0-30 points)
        if profile.ram_total_gb >= 16:
            score += 30
        elif profile.ram_total_gb >= 8:
            score += 20
        elif profile.ram_total_gb >= 4:
            score += 10
        else:
            score += 5

        # CPU frequency scoring (0-20 points)
        if profile.cpu_freq_max >= 3000:
            score += 20
        elif profile.cpu_freq_max >= 2500:
            score += 15
        elif profile.cpu_freq_max >= 2000:
            score += 10
        else:
            score += 5

        # GPU bonus (0-10 points)
        if profile.has_gpu:
            score += 10

        # Determine tier (thresholds mais baixos para melhor classificação)
        if score >= 70:  # Reduzido de 80
            profile.performance_tier = "ultra"
        elif score >= 50:  # Reduzido de 60
            profile.performance_tier = "high"
        elif score >= 35:  # Reduzido de 40
            profile.performance_tier = "medium"
        else:
            profile.performance_tier = "low"

        # Concurrency and memory budgets
        if profile.performance_tier == "ultra":
            target_ratio = 0.92
            reserve_for_os = 0.25
        elif profile.performance_tier == "high":
            target_ratio = 0.88
            reserve_for_os = 0.35
        elif profile.performance_tier == "medium":
            target_ratio = 0.80
            reserve_for_os = 0.45
        else:
            target_ratio = 0.72
            reserve_for_os = 0.6

        raw_budget = profile.ram_total_gb * target_ratio
        available_budget = profile.ram_available_gb * 0.95
        hard_cap = max(0.25, profile.ram_total_gb - reserve_for_os)
        hard_cap = min(hard_cap, profile.ram_total_gb * 0.98)
        usable_ram = max(0.25, min(max(raw_budget, available_budget), hard_cap))
        profile.ram_budget_gb = round(usable_ram, 2)

        sequential_signals = 0
        if profile.cpu_physical <= 2:
            sequential_signals += 1
        if profile.ram_total_gb <= 4:
            sequential_signals += 1
        if usable_ram <= 1.25:
            sequential_signals += 1
        if profile.performance_tier == "low":
            sequential_signals += 1
        if profile.performance_tier == "medium" and profile.cpu_freq_max < 2000:
            sequential_signals += 1

        sequential_threshold = 2
        if profile.performance_tier in ("high", "ultra") or (
            profile.cpu_physical >= 4 and profile.ram_total_gb >= 6
        ):
            sequential_threshold = 3

        profile.force_sequential = sequential_signals >= sequential_threshold
        profile.recommended_parallel = not profile.force_sequential

        if profile.performance_tier == "ultra":
            base_concurrency = max(6, min(profile.cpu_count, profile.cpu_physical * 3))
        elif profile.performance_tier == "high":
            base_concurrency = max(6, min(profile.cpu_count, profile.cpu_physical * 2 + 2))
        elif profile.performance_tier == "medium":
            base_concurrency = max(4, int(profile.cpu_physical * 1.5))
        else:
            base_concurrency = max(2, profile.cpu_physical)

        ram_per_segment = 0.18 if profile.performance_tier in ("high", "ultra") else 0.24
        ram_limit = max(1, int(usable_ram / ram_per_segment))
        profile.recommended_concurrency = max(
            4, min(12, min(base_concurrency, ram_limit))
        )  # Mínimo 4, máximo 12

        if profile.force_sequential:
            profile.recommended_concurrency = min(
                profile.recommended_concurrency, max(2, profile.cpu_physical)
            )

        if profile.force_sequential:
            chapter_parallel = 1
        else:
            if profile.performance_tier == "ultra":
                ram_per_chapter = 0.35  # Mais agressivo: menos RAM por capítulo
                hard_chapter_cap = 8  # Aumentado de 6 para 8
                cpu_guardrail = profile.cpu_physical + 2
                min_parallel = 4  # Aumentado de 3 para 4
            elif profile.performance_tier == "high":
                ram_per_chapter = 0.4  # Mais agressivo
                hard_chapter_cap = 6  # Aumentado de 5 para 6
                cpu_guardrail = profile.cpu_physical + 1
                min_parallel = 3  # Sempre 3 em vez de 2-3
            elif profile.performance_tier == "medium":
                ram_per_chapter = 0.55  # Mais agressivo
                hard_chapter_cap = 5  # Aumentado de 4 para 5
                cpu_guardrail = max(3, profile.cpu_physical)  # Mínimo 3
                min_parallel = 2  # Sempre 2 em vez de 1-2
            else:
                ram_per_chapter = 0.75  # Mais agressivo
                hard_chapter_cap = 3  # Aumentado de 2 para 3
                cpu_guardrail = max(2, profile.cpu_physical)  # Mínimo 2
                min_parallel = 2  # Aumentado de 1 para 2

            raw_parallel = max(1, int(usable_ram / ram_per_chapter))
            chapter_parallel = min(hard_chapter_cap, raw_parallel, max(1, cpu_guardrail))

            if (
                profile.performance_tier in ("high", "ultra")
                and profile.ram_total_gb >= 8
                and usable_ram >= 1.5
            ):
                chapter_parallel = max(min_parallel, chapter_parallel)
            else:
                chapter_parallel = max(min_parallel, chapter_parallel)

        profile.recommended_chapter_parallel = max(1, chapter_parallel)

    @staticmethod
    def print_profile(profile: HardwareProfile, verbose: bool = True) -> None:
        """Print hardware profile and recommendations."""

        print("=" * 60)
        print("🖥️  HARDWARE PROFILE & AUTO-OPTIMIZATION")
        print("=" * 60)

        # CPU
        print("\n💻 CPU:")
        print(f"   Model: {profile.cpu_brand}")
        print(f"   Cores: {profile.cpu_physical} physical, {profile.cpu_count} logical")
        print(f"   Frequency: {profile.cpu_freq_max:.0f} MHz")

        # RAM
        print("\n🧠 RAM:")
        print(f"   Total: {profile.ram_total_gb:.1f} GB")
        print(f"   Available: {profile.ram_available_gb:.1f} GB")
        if profile.ram_budget_gb:
            print(f"   Conversion Budget: {profile.ram_budget_gb:.1f} GB (auto target)")

        # GPU
        print("\n🎮 GPU:")
        if profile.has_gpu:
            print(f"   Type: {profile.gpu_type or 'Dedicated GPU'}")
            print("   Status: ✅ Available")
        else:
            print(f"   Type: {profile.gpu_type or 'Integrated/None'}")
            print("   Status: ❌ No dedicated GPU")

        # Platform
        print("\n🌐 Platform:")
        print(f"   OS: {profile.os_type}")
        print(f"   Network: {profile.network_speed_estimate.capitalize()}")

        # Performance tier
        tier_emoji = {"ultra": "🚀", "high": "⚡", "medium": "✅", "low": "⚠️"}
        tier_label = {
            "ultra": "Ultra (Flagship)",
            "high": "High (Enthusiast)",
            "medium": "Medium (Mainstream)",
            "low": "Low (Budget)",
        }

        print(
            f"\n{tier_emoji[profile.performance_tier]} Performance Tier: {tier_label[profile.performance_tier]}"
        )

        # Recommendations
        print("\n⚙️  OPTIMIZATIONS:")
        print(f"   Segment Concurrency: {profile.recommended_concurrency}")
        print(f"   Chapter Concurrency: {profile.recommended_chapter_parallel}")
        print(
            f"   Parallel Processing: {'✅ Enabled' if profile.recommended_parallel else '❌ Disabled'}"
        )
        chapter_mode = (
            "🚀 Parallel chapters (max priority)"
            if not profile.force_sequential
            else "🔒 Sequential chapters (faster for this hardware)"
        )
        print(f"   Chapter Strategy: {chapter_mode}")

        if profile.performance_tier == "ultra":
            print("   Strategy: Aggressive parallelism for maximum speed")
        elif profile.performance_tier == "high":
            print("   Strategy: Balanced aggressive for high performance")
        elif profile.performance_tier == "medium":
            print("   Strategy: Balanced for reliability and speed")
        else:
            print("   Strategy: Conservative for stability")

        print("\n" + "=" * 60)

    @staticmethod
    def apply_optimizations(profile: HardwareProfile) -> None:
        """Apply optimizations to environment."""

        def _env_truthy(name: str, default: bool = False) -> bool:
            raw = os.getenv(name)
            if raw is None:
                return default
            return raw.strip().lower() in {"1", "true", "on", "yes"}

        def _env_int(name: str, default: int) -> int:
            raw = os.getenv(name)
            if raw is None:
                return default
            raw = raw.strip()
            if raw == "":
                return default
            try:
                return int(raw)
            except ValueError:
                return default

        def _set_env_max(name: str, minimum: int) -> None:
            current = os.getenv(name)
            try:
                if current is None or int(current) < minimum:
                    os.environ[name] = str(minimum)
            except ValueError:
                os.environ[name] = str(minimum)

        turbo_mode = _env_truthy("MAX_PERFORMANCE", True)  # Turbo mode SEMPRE ativo por padrão

        edge_concurrency = profile.recommended_concurrency
        chapter_parallel = profile.recommended_chapter_parallel

        if turbo_mode:
            # **PERFORMANCE**: Aumentar para usar máxima CPU/RAM disponível
            if profile.performance_tier in ("ultra", "high"):
                edge_concurrency = max(edge_concurrency, 16)  # Aumentado de 10 para 16
                chapter_parallel = max(chapter_parallel, 8)  # Aumentado de 5 para 8
            elif profile.performance_tier == "medium":
                edge_concurrency = max(edge_concurrency, 12)  # Aumentado de 7 para 12
                chapter_parallel = max(chapter_parallel, 6)  # Aumentado de 3 para 6
            else:
                edge_concurrency = max(edge_concurrency, 8)  # Aumentado de 5 para 8
                chapter_parallel = max(chapter_parallel, 4)  # Aumentado de 2 para 4

        network_tier = (profile.network_speed_estimate or "fast").strip().lower()
        edge_profile = dict(
            HardwareDetector._EDGE_NETWORK_PROFILES.get(
                network_tier,
                HardwareDetector._EDGE_NETWORK_PROFILES["fast"],
            )
        )
        turbo_min_concurrency = _env_int("EDGE_TURBO_MIN_CONCURRENCY", 8)
        turbo_chunk_chars = _env_int("EDGE_TURBO_CHUNK_CHARS", 4000)
        turbo_segment_seconds = _env_int("EDGE_TURBO_MAX_SEGMENT_SECONDS", 45)
        turbo_ignore_caps = _env_truthy("EDGE_TURBO_IGNORE_NETWORK_CAPS", True)

        if turbo_mode:
            edge_profile["chunk_chars"] = max(
                int(edge_profile.get("chunk_chars") or 0), turbo_chunk_chars
            )
            edge_profile["max_segment_seconds"] = max(
                int(edge_profile.get("max_segment_seconds") or 0),
                turbo_segment_seconds,
            )
            edge_profile["edge_parallel"] = True
        try:
            scaled = float(edge_profile.get("concurrency_scale", 1.0))
        except (TypeError, ValueError):
            scaled = 1.0
        edge_concurrency = max(1, int(round(edge_concurrency * scaled)))
        try:
            cap = int(edge_profile.get("concurrency_cap", edge_concurrency))
        except (TypeError, ValueError):
            cap = edge_concurrency
        edge_concurrency = max(1, min(edge_concurrency, cap))
        if turbo_mode:
            if turbo_ignore_caps:
                edge_concurrency = max(edge_concurrency, turbo_min_concurrency)
            else:
                edge_concurrency = max(edge_concurrency, min(turbo_min_concurrency, cap))

        os.environ["EDGE_MAX_CONCURRENCY"] = str(edge_concurrency)
        os.environ["CHAPTER_PARALLEL_COUNT"] = str(chapter_parallel)
        os.environ["EDGE_FORCE_SEQUENTIAL"] = "true" if profile.force_sequential else "false"
        os.environ["EDGE_CHUNK_CHARS"] = str(edge_profile.get("chunk_chars", 20000))
        os.environ["EDGE_MAX_SEGMENT_SECONDS"] = str(edge_profile.get("max_segment_seconds", 75))
        os.environ["EDGE_ENABLE_PARALLEL"] = (
            "true" if edge_profile.get("edge_parallel", True) else "false"
        )
        if turbo_mode:
            os.environ.setdefault("EDGE_MAX_CONCURRENCY_CAP", str(max(8, turbo_min_concurrency)))

        # Set other performance hints
        if profile.performance_tier in ("ultra", "high"):
            os.environ["EDGE_AGGRESSIVE_MODE"] = "false"  # Parallel mode is better

        # Platform-specific optimizations
        if profile.is_macos and not profile.has_gpu:
            # Mac without dedicated GPU - use efficient settings
            # Intel Macs benefit from slightly lower concurrency
            if "Intel" in profile.cpu_brand:
                adjusted = max(2, edge_concurrency - 1)
                os.environ["EDGE_MAX_CONCURRENCY"] = str(adjusted)

        if turbo_mode:
            # **PERFORMANCE**: Mais workers para máxima utilização de CPU
            desired_workers = max(
                2,
                min(
                    16,  # Aumentado de 8 para 16
                    profile.cpu_physical * 2,  # Usar logical cores
                    chapter_parallel * 2,
                ),
            )
            _set_env_max("JOB_WORKERS", desired_workers)

        coqui_workers = max(2, min(8, profile.cpu_physical or profile.cpu_count or 2))
        if turbo_mode:
            cpu_base = profile.cpu_physical or profile.cpu_count or 2
            coqui_workers = max(coqui_workers, min(12, cpu_base * 2))
        elif profile.performance_tier in ("high", "ultra"):
            coqui_workers = max(coqui_workers, 4)
        os.environ["COQUI_MAX_WORKERS"] = str(coqui_workers)

        piper_procs = max(1, min(6, max(2, (profile.cpu_physical or 1) // 2)))
        if profile.performance_tier in ("high", "ultra"):
            piper_procs = max(piper_procs, 3)
        os.environ["PIPER_MAX_PROCS"] = str(piper_procs)

        with contextlib.suppress(Exception):
            from .benchmark_profile import apply_global_overrides

            apply_global_overrides()


__all__ = ["HardwareDetector", "HardwareProfile"]
