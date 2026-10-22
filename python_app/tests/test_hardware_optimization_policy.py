"""Hardware policy extraction preserves profile identity and caller-owned probes."""

import os
from unittest.mock import Mock, patch

import pytest
from src import benchmark_profile
from src.hardware_detector import HardwareDetector, HardwareProfile


def _profile(**overrides):
    values = dict(
        cpu_count=4, cpu_physical=2, cpu_freq_max=2400.0, cpu_brand="fixture",
        ram_total_gb=4.0, ram_available_gb=1.0, has_gpu=False,
        network_speed_estimate="fast", os_type="Linux",
    )
    values.update(overrides)
    return HardwareProfile(**values)


def test_recommendations_update_the_same_profile_and_respect_low_memory_fixture():
    profile = _profile()
    identity = id(profile)
    HardwareDetector._calculate_recommendations(profile)
    assert id(profile) == identity
    assert profile.performance_tier == "low"
    assert profile.force_sequential
    assert not profile.recommended_parallel
    assert profile.recommended_chapter_parallel == 1
    assert profile.ram_budget_gb == 0.95


def test_apply_uses_replaceable_network_policy_and_thermal_probe(monkeypatch):
    profile = _profile(is_macos=True)
    thermal = Mock(return_value=(1, "fixture-mode"))
    monkeypatch.setattr(HardwareDetector, "_detect_macos_power_thermal_cap", thermal)
    monkeypatch.setattr(HardwareDetector, "_EDGE_NETWORK_PROFILES", {
        "fast": {"chunk_chars": 1234, "max_segment_seconds": 17, "concurrency_scale": 1.0, "concurrency_cap": 3, "edge_parallel": False},
    })
    monkeypatch.setattr(benchmark_profile, "apply_global_overrides", Mock())
    with patch.dict(os.environ, {"MAX_PERFORMANCE": "0"}, clear=True):
        HardwareDetector.apply_optimizations(profile)
        assert os.environ["EDGE_CHUNK_CHARS"] == "1234"
        assert os.environ["EDGE_MAX_SEGMENT_SECONDS"] == "17"
        assert os.environ["THERMAL_PARALLEL_CAP"] == "1"
        assert os.environ["THERMAL_POWER_MODE"] == "fixture-mode"
        thermal.assert_called_once()


@pytest.mark.parametrize("error", [RuntimeError("probe failed"), KeyboardInterrupt()])
def test_thermal_probe_failure_and_cancellation_keep_existing_exception_surface(error, monkeypatch):
    monkeypatch.setattr(HardwareDetector, "_detect_macos_power_thermal_cap", Mock(side_effect=error))
    monkeypatch.setattr(benchmark_profile, "apply_global_overrides", Mock())
    with patch.dict(os.environ, {"MAX_PERFORMANCE": "0"}, clear=True):
        with pytest.raises(type(error)):
            HardwareDetector.apply_optimizations(_profile(is_macos=True))
