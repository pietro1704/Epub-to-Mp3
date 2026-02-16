#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Hardware and network monitoring system for performance auto-tuning.

Detects:
- CPU cores, speed
- Total/available RAM
- GPU (CUDA, Metal, CPU)
- Storage type (SSD vs HDD)
- Real-time network speed
- Latency and throttling
"""

import asyncio
import os
import platform
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Optional

try:
    import psutil

    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False

_disable_torch = str(os.getenv("DISABLE_TORCH", "")).strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
if platform.system().lower() == "darwin":
    _disable_torch = True
_allow_no_shm = str(os.getenv("ALLOW_TORCH_NO_SHM", "")).strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
_shm_available = Path("/dev/shm").exists()

if _disable_torch or (not _shm_available and not _allow_no_shm):
    TORCH_AVAILABLE = False
else:
    try:
        import torch

        TORCH_AVAILABLE = True
    except ImportError:
        TORCH_AVAILABLE = False


@dataclass
class HardwareSpecs:
    """Detected hardware specifications."""

    cpu_cores: int
    cpu_physical_cores: int
    cpu_freq_mhz: float
    ram_total_gb: float
    ram_available_gb: float
    gpu_available: bool
    gpu_type: Literal["cuda", "metal", "cpu"]
    gpu_name: Optional[str]
    storage_type: Literal["ssd", "hdd", "unknown"]
    platform: str


@dataclass
class NetworkStats:
    """Network statistics."""

    download_mbps: float
    latency_ms: float
    tier: Literal["slow", "medium", "fast", "ultra"]
    sample_count: int
    last_measured: float


class SystemMonitor:
    """System monitor for auto-tuning."""

    def __init__(self, verbose: bool = True):
        self.verbose = verbose
        self._hw_specs: Optional[HardwareSpecs] = None
        self._network_stats: Optional[NetworkStats] = None
        self._network_samples: list[tuple[float, float]] = []  # (mbps, latency)

    def detect_hardware(self) -> HardwareSpecs:
        """Detect hardware specifications."""
        if self._hw_specs:
            return self._hw_specs

        # CPU
        cpu_cores = os.cpu_count() or 4
        cpu_physical_cores = cpu_cores
        cpu_freq_mhz = 0.0

        if PSUTIL_AVAILABLE:
            cpu_physical_cores = psutil.cpu_count(logical=False) or cpu_cores
            try:
                freq = psutil.cpu_freq()
                if freq:
                    cpu_freq_mhz = freq.current
            except Exception:
                pass

        # RAM
        ram_total_gb = 8.0
        ram_available_gb = 4.0

        if PSUTIL_AVAILABLE:
            try:
                mem = psutil.virtual_memory()
                ram_total_gb = mem.total / (1024**3)
                ram_available_gb = mem.available / (1024**3)
            except Exception:
                pass

        # GPU
        gpu_available = False
        gpu_type: Literal["cuda", "metal", "cpu"] = "cpu"
        gpu_name: Optional[str] = None

        if TORCH_AVAILABLE:
            if torch.cuda.is_available():
                gpu_available = True
                gpu_type = "cuda"
                try:
                    gpu_name = torch.cuda.get_device_name(0)
                except Exception:
                    gpu_name = "CUDA GPU"
            elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                gpu_available = True
                gpu_type = "metal"
                gpu_name = "Apple Metal GPU"

        # Storage type (simple heuristic)
        storage_type: Literal["ssd", "hdd", "unknown"] = "unknown"
        if PSUTIL_AVAILABLE and platform.system() != "Windows":
            try:
                # Quick write speed test
                test_file = Path("/tmp/.storage_test")
                data = b"0" * (1024 * 1024)  # 1MB
                start = time.perf_counter()
                test_file.write_bytes(data)
                test_file.unlink()
                write_time = time.perf_counter() - start

                # SSD typically < 10ms for 1MB, HDD > 50ms
                if write_time < 0.015:
                    storage_type = "ssd"
                elif write_time > 0.05:
                    storage_type = "hdd"
            except Exception:
                pass

        self._hw_specs = HardwareSpecs(
            cpu_cores=cpu_cores,
            cpu_physical_cores=cpu_physical_cores,
            cpu_freq_mhz=cpu_freq_mhz,
            ram_total_gb=ram_total_gb,
            ram_available_gb=ram_available_gb,
            gpu_available=gpu_available,
            gpu_type=gpu_type,
            gpu_name=gpu_name,
            storage_type=storage_type,
            platform=platform.system(),
        )

        if self.verbose:
            self._print_hw_specs()

        return self._hw_specs

    def _print_hw_specs(self) -> None:
        """Print hardware specifications."""
        if not self._hw_specs:
            return

        hw = self._hw_specs
        print("\n" + "=" * 70)
        print("🖥️  DETECTED HARDWARE")
        print("=" * 70)
        print(f"CPU: {hw.cpu_physical_cores} physical cores, {hw.cpu_cores} threads")
        if hw.cpu_freq_mhz > 0:
            print(f"     {hw.cpu_freq_mhz:.0f} MHz")
        print(f"RAM: {hw.ram_available_gb:.1f} GB available / {hw.ram_total_gb:.1f} GB total")
        if hw.gpu_available:
            print(f"GPU: {hw.gpu_name} ({hw.gpu_type.upper()})")
        else:
            print("GPU: Not available (using CPU)")
        print(f"Storage: {hw.storage_type.upper()}")
        print(f"Platform: {hw.platform}")
        print("=" * 70 + "\n")

    async def measure_network_speed(
        self,
        test_url: str = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1",
        test_size_kb: int = 50,
        timeout: float = 10.0,
    ) -> tuple[float, float]:
        """
        Measure network speed (Mbps) and latency (ms).

        Returns:
            (download_mbps, latency_ms)
        """
        try:
            import aiohttp

            # Simulate Edge-TTS request
            headers = {
                "User-Agent": "Mozilla/5.0",
                "Accept": "*/*",
            }

            # Latency: handshake time
            latency_start = time.perf_counter()

            async with aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=timeout)
            ) as session:
                # HEAD request to measure latency
                try:
                    async with session.head(test_url, headers=headers) as response:
                        latency_ms = (time.perf_counter() - latency_start) * 1000
                except Exception:
                    latency_ms = 999.0

                # Download speed: simulate small chunk
                # Edge-TTS returns audio, so we simulate with a small request
                download_start = time.perf_counter()
                try:
                    # Use a speed test server if available
                    test_data_url = "https://speed.cloudflare.com/__down?bytes=51200"  # 50KB
                    async with session.get(test_data_url, headers=headers) as response:
                        data = await response.read()
                        download_time = time.perf_counter() - download_start

                        if download_time > 0:
                            bytes_downloaded = len(data)
                            mbps = (bytes_downloaded * 8) / (download_time * 1_000_000)
                        else:
                            mbps = 0.0
                except Exception:
                    # Fallback: assume conservative speed
                    mbps = 10.0
                    if latency_ms < 50:
                        mbps = 50.0
                    elif latency_ms < 100:
                        mbps = 25.0

                return mbps, latency_ms

        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Failed to measure network speed: {exc}")
            # Conservative default values
            return 10.0, 100.0

    async def classify_network(self) -> NetworkStats:
        """
        Classify the network into tiers based on multiple samples.

        Returns:
            NetworkStats with tier: slow/medium/fast/ultra
        """
        if self._network_stats and (time.time() - self._network_stats.last_measured) < 60:
            # Cache valid for 1 minute
            return self._network_stats

        if self.verbose:
            print("🌐 Measuring network speed...")

        # Collect 3 quick samples
        samples = []
        for i in range(3):
            mbps, latency = await self.measure_network_speed()
            samples.append((mbps, latency))
            if i < 2:
                await asyncio.sleep(0.5)

        # Calculate average
        avg_mbps = sum(s[0] for s in samples) / len(samples)
        avg_latency = sum(s[1] for s in samples) / len(samples)

        # Classify tier
        # Takes into account both speed and latency
        tier: Literal["slow", "medium", "fast", "ultra"] = "medium"

        if avg_mbps >= 100 and avg_latency < 50:
            tier = "ultra"
        elif avg_mbps >= 50 and avg_latency < 100:
            tier = "fast"
        elif avg_mbps >= 20 and avg_latency < 150:
            tier = "medium"
        else:
            tier = "slow"

        self._network_stats = NetworkStats(
            download_mbps=avg_mbps,
            latency_ms=avg_latency,
            tier=tier,
            sample_count=len(samples),
            last_measured=time.time(),
        )

        if self.verbose:
            print(f"   Speed: {avg_mbps:.1f} Mbps")
            print(f"   Latency: {avg_latency:.1f} ms")
            print(f"   🎯 Network tier: {tier.upper()}\n")

        return self._network_stats

    def get_current_stats(self) -> tuple[HardwareSpecs, Optional[NetworkStats]]:
        """Return current specs (hw always, network if already measured)."""
        hw = self.detect_hardware()
        return hw, self._network_stats
