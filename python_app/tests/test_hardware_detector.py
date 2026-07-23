"""Tests for hardware-derived runtime limits."""

import os
import sys
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.hardware_detector import HardwareDetector, HardwareProfile


def _profile(*, ram_total_gb: float, ram_available_gb: float) -> HardwareProfile:
    return HardwareProfile(
        cpu_count=8,
        cpu_physical=4,
        cpu_freq_max=2400.0,
        cpu_brand="Test CPU",
        ram_total_gb=ram_total_gb,
        ram_available_gb=ram_available_gb,
        has_gpu=False,
        network_speed_estimate="fast",
        os_type="Darwin",
        is_macos=False,
        recommended_concurrency=12,
        recommended_chapter_parallel=8,
        performance_tier="high",
    )


def _clean_environment() -> dict[str, str]:
    values = dict(os.environ)
    for name in (
        "CHAPTER_PARALLEL_COUNT",
        "CHAPTER_PARALLEL_COUNT_SOURCE",
        "EDGE_MAX_CONCURRENCY",
        "EDGE_MAX_CONCURRENCY_SOURCE",
        "EDGE_MAX_CONCURRENCY_CAP",
        "EDGE_CHUNK_CHARS",
        "EDGE_MAX_SEGMENT_SECONDS",
        "EDGE_ENABLE_PARALLEL",
        "EDGE_FORCE_SEQUENTIAL",
        "PIPER_MAX_PROCS",
        "JOB_WORKERS",
    ):
        values.pop(name, None)
    return values


def test_low_available_ram_clamps_chapters_without_clamping_edge_requests():
    profile = _profile(ram_total_gb=8.0, ram_available_gb=1.0)

    with patch.dict(os.environ, _clean_environment(), clear=True):
        HardwareDetector.apply_optimizations(profile)

        assert os.environ["CHAPTER_PARALLEL_COUNT"] == "2"
        assert int(os.environ["EDGE_MAX_CONCURRENCY"]) >= 8


def test_explicit_chapter_override_is_preserved_under_low_ram():
    profile = _profile(ram_total_gb=8.0, ram_available_gb=1.0)
    values = _clean_environment()
    values["CHAPTER_PARALLEL_COUNT"] = "7"

    with patch.dict(os.environ, values, clear=True):
        HardwareDetector.apply_optimizations(profile)

        assert os.environ["CHAPTER_PARALLEL_COUNT"] == "7"
