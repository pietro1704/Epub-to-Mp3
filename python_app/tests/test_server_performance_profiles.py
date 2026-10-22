"""Deployment profile extraction preserves explicit settings and literal defaults."""

import os
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from src import _server_engine_helpers as facade
from src import server_performance_profiles as profiles


@pytest.mark.parametrize("profile", ["hf", "local", "cli"])
def test_profile_defaults_preserve_explicit_operator_values(profile):
    hardware = SimpleNamespace(cpu_physical=8, has_gpu=False)
    with patch.dict(os.environ, {"EDGE_CHUNK_CHARS": "7777"}, clear=True):
        facade._apply_perf_defaults(profile, hardware)
        assert os.environ["EDGE_CHUNK_CHARS"] == "7777"
        assert int(os.environ["EDGE_MAX_CONCURRENCY"]) >= 1


def test_hf_profile_keeps_literal_serial_limits_and_repeated_application():
    hardware = SimpleNamespace(cpu_physical=2, has_gpu=False)
    assert facade._apply_perf_defaults is profiles._apply_perf_defaults
    with patch.dict(os.environ, {}, clear=True):
        facade._apply_perf_defaults("hf", hardware)
        first = dict(os.environ)
        assert first["EDGE_ENABLE_PARALLEL"] == "false"
        assert first["CHAPTER_PARALLEL_COUNT"] == "1"
        assert first["EDGE_CHUNK_CHARS"] == "12000"
        facade._apply_perf_defaults("hf", hardware)
        assert dict(os.environ) == first


def test_unknown_profile_preserves_existing_balanced_fallback():
    with patch.dict(os.environ, {"CUSTOM": "preserved"}, clear=True):
        facade._apply_perf_defaults("unknown", SimpleNamespace(cpu_physical=2))
        assert os.environ["CUSTOM"] == "preserved"
        assert os.environ["EDGE_CHUNK_CHARS"] == "10000"
        assert os.environ["CHAPTER_PARALLEL_COUNT"] == "2"
