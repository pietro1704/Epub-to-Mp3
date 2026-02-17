#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for auto-tuner module."""

import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import pytest

from python_app.src.auto_tuner import AutoTuner
from python_app.src.hardware_monitor import HardwareSpecs, NetworkStats


class TestAutoTuner(unittest.IsolatedAsyncioTestCase):
    def test_select_profile_conservative_low_specs(self):
        """Low specs should select conservative profile."""
        tuner = AutoTuner(verbose=False)

        hw = HardwareSpecs(
            cpu_cores=2,
            cpu_physical_cores=2,
            cpu_freq_mhz=2000.0,
            ram_total_gb=4.0,
            ram_available_gb=2.0,
            gpu_available=False,
            gpu_type="cpu",
            gpu_name=None,
            storage_type="hdd",
            platform="Linux",
        )

        network = NetworkStats(
            download_mbps=15.0, latency_ms=120.0, tier="slow", sample_count=3, last_measured=0.0
        )

        profile = tuner.select_profile(hw, network)
        self.assertEqual(profile.name, "Conservative")
        self.assertLessEqual(profile.edge_max_concurrency, 4)

    def test_select_profile_maximum_high_specs(self):
        """High specs should select maximum profile."""
        tuner = AutoTuner(verbose=False)

        hw = HardwareSpecs(
            cpu_cores=32,
            cpu_physical_cores=16,
            cpu_freq_mhz=3500.0,
            ram_total_gb=64.0,
            ram_available_gb=48.0,
            gpu_available=True,
            gpu_type="cuda",
            gpu_name="RTX 4090",
            storage_type="ssd",
            platform="Linux",
        )

        network = NetworkStats(
            download_mbps=500.0, latency_ms=10.0, tier="ultra", sample_count=3, last_measured=0.0
        )

        profile = tuner.select_profile(hw, network)
        self.assertEqual(profile.name, "Maximum")
        self.assertGreaterEqual(profile.edge_max_concurrency, 10)

    def test_apply_profile_sets_env_vars(self):
        """Apply profile should set environment variables."""
        tuner = AutoTuner(verbose=False)
        profile = tuner.PROFILES["balanced"]

        # Clear env vars
        for key in [
            "EDGE_MAX_CONCURRENCY",
            "EDGE_CHUNK_CHARS",
            "COQUI_MAX_WORKERS",
            "PIPER_MAX_PROCS",
        ]:
            os.environ.pop(key, None)

        tuner.apply_profile(profile, force=True)

        self.assertEqual(os.environ["EDGE_MAX_CONCURRENCY"], str(profile.edge_max_concurrency))
        self.assertEqual(os.environ["EDGE_CHUNK_CHARS"], str(profile.edge_chunk_chars))
        self.assertEqual(os.environ["COQUI_MAX_WORKERS"], str(profile.coqui_max_workers))
        self.assertEqual(os.environ["PIPER_MAX_PROCS"], str(profile.piper_max_workers))

    def test_apply_profile_respects_existing_vars(self):
        """Apply profile should not override existing vars unless force=True."""
        tuner = AutoTuner(verbose=False)
        profile = tuner.PROFILES["balanced"]

        # Set existing var
        os.environ["EDGE_MAX_CONCURRENCY"] = "999"

        tuner.apply_profile(profile, force=False)

        # Should not override
        self.assertEqual(os.environ["EDGE_MAX_CONCURRENCY"], "999")

        tuner.apply_profile(profile, force=True)

        # Should override
        self.assertEqual(os.environ["EDGE_MAX_CONCURRENCY"], str(profile.edge_max_concurrency))

    def test_adjust_profile_reduces_workers_low_ram(self):
        """Low RAM should reduce workers."""
        tuner = AutoTuner(verbose=False)

        hw = HardwareSpecs(
            cpu_cores=8,
            cpu_physical_cores=4,
            cpu_freq_mhz=2500.0,
            ram_total_gb=8.0,
            ram_available_gb=2.0,  # Low available
            gpu_available=False,
            gpu_type="cpu",
            gpu_name=None,
            storage_type="ssd",
            platform="Linux",
        )

        profile = tuner.PROFILES["performance"]
        adjusted = tuner._adjust_profile(profile, hw, None)

        # Should reduce chapter parallel
        self.assertLess(adjusted.edge_safe_chapter_parallel, profile.edge_safe_chapter_parallel)

    @patch("python_app.src.hardware_monitor.SystemMonitor.detect_hardware")
    @patch("python_app.src.hardware_monitor.SystemMonitor.classify_network")
    async def test_auto_configure(self, mock_classify_network, mock_detect_hardware):
        """Auto-configure should detect and apply profile."""
        # Mock hardware detection
        mock_hw = HardwareSpecs(
            cpu_cores=8,
            cpu_physical_cores=4,
            cpu_freq_mhz=2800.0,
            ram_total_gb=16.0,
            ram_available_gb=10.0,
            gpu_available=False,
            gpu_type="cpu",
            gpu_name=None,
            storage_type="ssd",
            platform="Darwin",
        )
        mock_detect_hardware.return_value = mock_hw

        # Mock network classification
        mock_network = NetworkStats(
            download_mbps=80.0, latency_ms=30.0, tier="fast", sample_count=3, last_measured=0.0
        )
        mock_classify_network.return_value = mock_network

        tuner = AutoTuner(verbose=False)

        # Clear env
        os.environ.pop("EDGE_MAX_CONCURRENCY", None)

        profile = await tuner.auto_configure(force=True, measure_network=True)

        # Should select performance or balanced
        self.assertIn(profile.name, ["Balanced", "Performance"])

        # Should set env vars
        self.assertIn("EDGE_MAX_CONCURRENCY", os.environ)

    @patch("python_app.src.hardware_monitor.SystemMonitor.detect_hardware")
    @patch("python_app.src.hardware_monitor.SystemMonitor.classify_network")
    async def test_auto_configure_uses_cached_profile(
        self, mock_classify_network, mock_detect_hardware
    ):
        """When cache is fresh, auto-configure should skip probing."""
        with TemporaryDirectory() as tmp_dir:
            cache_path = Path(tmp_dir) / "auto_tune_profile.json"
            os.environ["AUTO_TUNE_CACHE_FILE"] = str(cache_path)
            os.environ["AUTO_TUNE_CACHE_TTL_SECONDS"] = "3600"
            os.environ["AUTO_TUNE_USE_CACHE"] = "1"

            tuner = AutoTuner(verbose=False)
            tuner._save_cached_profile(tuner.PROFILES["maximum"])

            profile = await tuner.auto_configure(force=False, measure_network=True)

            self.assertEqual(profile.name, "Maximum")
            mock_detect_hardware.assert_not_called()
            mock_classify_network.assert_not_called()

        os.environ.pop("AUTO_TUNE_CACHE_FILE", None)
        os.environ.pop("AUTO_TUNE_CACHE_TTL_SECONDS", None)
        os.environ.pop("AUTO_TUNE_USE_CACHE", None)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
