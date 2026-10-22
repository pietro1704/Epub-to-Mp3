# -*- coding: utf-8 -*-
"""
Hardware detection and automatic performance optimization.

Detects CPU, RAM, GPU, and network capabilities to automatically
configure optimal conversion settings for maximum speed.
"""

from __future__ import annotations

import os
import platform
import re
import socket
import statistics
import subprocess
import time
from dataclasses import dataclass
from typing import Optional

import psutil

from .hardware_optimization_policy import apply_optimizations, calculate_recommendations


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
    recommended_concurrency: int = 8  # More aggressive default for better performance
    recommended_parallel: bool = True
    recommended_chapter_parallel: int = 3  # Optimized default: process 3 chapters simultaneously
    performance_tier: str = "high"  # Default "high" for better performance
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
        calculate_recommendations(profile)

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
        apply_optimizations(
            profile, network_profiles=HardwareDetector._EDGE_NETWORK_PROFILES,
            thermal_cap=HardwareDetector._detect_macos_power_thermal_cap,
        )

    @staticmethod
    def _detect_macos_power_thermal_cap(current_parallel: int) -> tuple[int, str]:
        if platform.system().lower() != "darwin":
            return max(1, int(current_parallel or 1)), "normal"
        cap = max(1, int(current_parallel or 1))
        mode = "normal"
        try:
            batt = subprocess.run(
                ["pmset", "-g", "batt"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            out = str(batt.stdout or "").lower()
            if "battery power" in out:
                mode = "battery"
                cap = max(1, min(cap, int(round(cap * 0.7))))
        except Exception:
            pass
        try:
            therm = subprocess.run(
                ["pmset", "-g", "therm"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            out = str(therm.stdout or "")
            match = re.search(r"CPU_Speed_Limit\\s*=\\s*(\\d+)", out, flags=re.IGNORECASE)
            if match:
                limit = int(match.group(1))
                if limit < 75:
                    mode = "thermal_hot"
                    cap = max(1, min(cap, int(round(current_parallel * 0.5))))
                elif limit < 90:
                    if mode == "normal":
                        mode = "thermal_warm"
                    cap = max(1, min(cap, int(round(current_parallel * 0.75))))
        except Exception:
            pass
        return max(1, int(cap)), mode


__all__ = ["HardwareDetector", "HardwareProfile"]
