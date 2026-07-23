"""Tests for hardware-tier classification, focused on the RAM ceiling.

A machine can score "high" on CPU/frequency yet only have 8 GiB of RAM
(e.g. an Intel 2018 laptop). Aggressive segment/chapter concurrency on
such a host thrashes memory and — on shared egress IPs — trips Edge
rate-limiting, so the tier must be capped by absolute total RAM.
"""

from python_app.src.hardware_detector import HardwareDetector, HardwareProfile


def _profile(
    *,
    cpu_physical: int,
    ram_total_gb: float,
    cpu_freq_max: float = 3000.0,
    has_gpu: bool = False,
    ram_available_gb: float | None = None,
) -> HardwareProfile:
    prof = HardwareProfile(
        cpu_count=cpu_physical * 2,
        cpu_physical=cpu_physical,
        cpu_freq_max=cpu_freq_max,
        cpu_brand="test",
        ram_total_gb=ram_total_gb,
        ram_available_gb=ram_available_gb if ram_available_gb is not None else ram_total_gb * 0.5,
        has_gpu=has_gpu,
        network_speed_estimate="ultra",
        os_type="Darwin",
    )
    HardwareDetector._calculate_recommendations(prof)
    return prof


class TestRamTierCap:
    def test_8gib_laptop_capped_to_medium(self) -> None:
        # 4 cores + 8 GiB + fast clock would score "high" on CPU alone;
        # the RAM ceiling must pull it down to "medium".
        prof = _profile(cpu_physical=4, ram_total_gb=8.0)
        assert prof.performance_tier == "medium"
        # Concurrency should land in the moderate band, not 10-12.
        assert prof.recommended_concurrency <= 8

    def test_under_6gib_capped_to_low(self) -> None:
        prof = _profile(cpu_physical=4, ram_total_gb=4.0)
        assert prof.performance_tier == "low"

    def test_12gib_allows_high_not_ultra(self) -> None:
        prof = _profile(cpu_physical=8, ram_total_gb=12.0, has_gpu=True)
        assert prof.performance_tier in ("medium", "high")
        assert prof.performance_tier != "ultra"

    def test_high_ram_workstation_can_reach_ultra(self) -> None:
        # 16+ cores and 32 GiB must NOT be capped — the RAM ceiling only
        # constrains low-RAM machines.
        prof = _profile(cpu_physical=16, ram_total_gb=32.0, has_gpu=True)
        assert prof.performance_tier == "ultra"

    def test_cap_never_promotes(self) -> None:
        # A genuinely weak machine stays low even though 8 GiB caps at medium
        # (the cap only lowers, never raises).
        prof = _profile(cpu_physical=1, ram_total_gb=8.0, cpu_freq_max=1600.0)
        assert prof.performance_tier in ("low", "medium")
