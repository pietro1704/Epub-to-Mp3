# -*- coding: utf-8 -*-
"""
Hardware detection and automatic performance optimization.

Detects CPU, RAM, GPU, and network capabilities to automatically
configure optimal conversion settings for maximum speed.
"""

from __future__ import annotations

import os
import platform
import psutil
import subprocess
from dataclasses import dataclass
from typing import Optional, Dict, Any
import sys


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
    recommended_concurrency: int = 4
    recommended_parallel: bool = True
    recommended_chapter_parallel: int = 1  # How many chapters to process simultaneously
    performance_tier: str = "medium"  # "low", "medium", "high", "ultra"
    ram_budget_gb: float = 0.0  # RAM amount converter is allowed to consume aggressively
    force_sequential: bool = False  # True when chapter-level parallelism would slow things down


class HardwareDetector:
    """Detect hardware capabilities and recommend optimal settings."""

    @staticmethod
    def detect() -> HardwareProfile:
        """Detect system hardware and return optimization profile."""

        # CPU detection
        cpu_count = psutil.cpu_count(logical=True) or 4
        cpu_physical = psutil.cpu_count(logical=False) or 2

        try:
            cpu_freq = psutil.cpu_freq()
            cpu_freq_max = cpu_freq.max if cpu_freq else 2400.0
        except Exception:
            cpu_freq_max = 2400.0

        cpu_brand = HardwareDetector._detect_cpu_brand()

        # Memory detection
        mem = psutil.virtual_memory()
        ram_total_gb = mem.total / (1024**3)
        ram_available_gb = mem.available / (1024**3)

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
                    timeout=2
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
                    ["wmic", "cpu", "get", "name"],
                    capture_output=True,
                    text=True,
                    timeout=2
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
                    timeout=5
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
                    result = subprocess.run(
                        ["lspci"],
                        capture_output=True,
                        text=True,
                        timeout=2
                    )
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
                    timeout=2
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
        # This is a placeholder - could be enhanced with actual speed test
        # For now, assume "fast" as default
        return "fast"

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

        # Determine tier
        if score >= 80:
            profile.performance_tier = "ultra"
        elif score >= 60:
            profile.performance_tier = "high"
        elif score >= 40:
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
        profile.recommended_concurrency = max(1, min(10, min(base_concurrency, ram_limit)))

        if profile.force_sequential:
            profile.recommended_concurrency = min(profile.recommended_concurrency, max(2, profile.cpu_physical))

        if profile.force_sequential:
            chapter_parallel = 1
        else:
            if profile.performance_tier == "ultra":
                ram_per_chapter = 0.45
                hard_chapter_cap = 6
                cpu_guardrail = profile.cpu_physical + 2
                min_parallel = 3
            elif profile.performance_tier == "high":
                ram_per_chapter = 0.5
                hard_chapter_cap = 5
                cpu_guardrail = profile.cpu_physical + 1
                min_parallel = 2 if profile.cpu_physical < 4 else 3
            elif profile.performance_tier == "medium":
                ram_per_chapter = 0.65
                hard_chapter_cap = 4
                cpu_guardrail = max(2, profile.cpu_physical)
                min_parallel = 2 if profile.cpu_physical >= 4 else 1
            else:
                ram_per_chapter = 0.85
                hard_chapter_cap = 2
                cpu_guardrail = max(1, profile.cpu_physical)
                min_parallel = 1

            raw_parallel = max(1, int(usable_ram / ram_per_chapter))
            chapter_parallel = min(hard_chapter_cap, raw_parallel, max(1, cpu_guardrail))

            if profile.performance_tier in ("high", "ultra") and profile.ram_total_gb >= 8 and usable_ram >= 1.5:
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
        print(f"\n💻 CPU:")
        print(f"   Model: {profile.cpu_brand}")
        print(f"   Cores: {profile.cpu_physical} physical, {profile.cpu_count} logical")
        print(f"   Frequency: {profile.cpu_freq_max:.0f} MHz")

        # RAM
        print(f"\n🧠 RAM:")
        print(f"   Total: {profile.ram_total_gb:.1f} GB")
        print(f"   Available: {profile.ram_available_gb:.1f} GB")
        if profile.ram_budget_gb:
            print(f"   Conversion Budget: {profile.ram_budget_gb:.1f} GB (auto target)")

        # GPU
        print(f"\n🎮 GPU:")
        if profile.has_gpu:
            print(f"   Type: {profile.gpu_type or 'Dedicated GPU'}")
            print(f"   Status: ✅ Available")
        else:
            print(f"   Type: {profile.gpu_type or 'Integrated/None'}")
            print(f"   Status: ❌ No dedicated GPU")

        # Platform
        print(f"\n🌐 Platform:")
        print(f"   OS: {profile.os_type}")
        print(f"   Network: {profile.network_speed_estimate.capitalize()}")

        # Performance tier
        tier_emoji = {
            "ultra": "🚀",
            "high": "⚡",
            "medium": "✅",
            "low": "⚠️"
        }
        tier_label = {
            "ultra": "Ultra (Flagship)",
            "high": "High (Enthusiast)",
            "medium": "Medium (Mainstream)",
            "low": "Low (Budget)"
        }

        print(f"\n{tier_emoji[profile.performance_tier]} Performance Tier: {tier_label[profile.performance_tier]}")

        # Recommendations
        print(f"\n⚙️  OPTIMIZATIONS:")
        print(f"   Segment Concurrency: {profile.recommended_concurrency}")
        print(f"   Chapter Concurrency: {profile.recommended_chapter_parallel}")
        print(f"   Parallel Processing: {'✅ Enabled' if profile.recommended_parallel else '❌ Disabled'}")
        chapter_mode = "🚀 Parallel chapters (max priority)" if not profile.force_sequential else "🔒 Sequential chapters (faster for this hardware)"
        print(f"   Chapter Strategy: {chapter_mode}")

        if profile.performance_tier == "ultra":
            print(f"   Strategy: Aggressive parallelism for maximum speed")
        elif profile.performance_tier == "high":
            print(f"   Strategy: Balanced aggressive for high performance")
        elif profile.performance_tier == "medium":
            print(f"   Strategy: Balanced for reliability and speed")
        else:
            print(f"   Strategy: Conservative for stability")

        print("\n" + "=" * 60)

    @staticmethod
    def apply_optimizations(profile: HardwareProfile) -> None:
        """Apply optimizations to environment."""
        os.environ["EDGE_MAX_CONCURRENCY"] = str(profile.recommended_concurrency)
        os.environ["CHAPTER_PARALLEL_COUNT"] = str(profile.recommended_chapter_parallel)
        os.environ["EDGE_FORCE_SEQUENTIAL"] = "true" if profile.force_sequential else "false"

        # Set other performance hints
        if profile.performance_tier in ("ultra", "high"):
            os.environ["EDGE_AGGRESSIVE_MODE"] = "false"  # Parallel mode is better

        # Platform-specific optimizations
        if profile.is_macos and not profile.has_gpu:
            # Mac without dedicated GPU - use efficient settings
            # Intel Macs benefit from slightly lower concurrency
            if "Intel" in profile.cpu_brand:
                adjusted = max(2, profile.recommended_concurrency - 1)
                os.environ["EDGE_MAX_CONCURRENCY"] = str(adjusted)


__all__ = ["HardwareDetector", "HardwareProfile"]
