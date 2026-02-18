# -*- coding: utf-8 -*-
"""Tests for machine-scoped performance profile persistence."""

from __future__ import annotations

from pathlib import Path

from src.performance_profile_store import PerformanceProfileStore


def test_machine_signature_roundtrip(tmp_path: Path) -> None:
    store = PerformanceProfileStore(path=tmp_path / "profiles.json")
    updated = store.upsert_profile(
        engine="edge",
        voice="v1",
        language="pt",
        machine_signature="darwin-c8-r16-nfast",
        chars_per_second=123.0,
        params={"edge_chunk_chars": 12000},
    )
    assert updated is True
    entry = store.get_profile(
        engine="edge",
        voice="v1",
        language="pt",
        machine_signature="darwin-c8-r16-nfast",
    )
    assert entry is not None
    assert float(entry.get("best_chars_per_second", 0.0)) == 123.0


def test_machine_signature_fallback_compatibility(tmp_path: Path) -> None:
    store = PerformanceProfileStore(path=tmp_path / "profiles.json")
    store.upsert_profile(
        engine="edge",
        voice="v1",
        language="pt",
        machine_signature="",
        chars_per_second=110.0,
        params={"edge_chunk_chars": 10000},
    )
    entry = store.get_profile(
        engine="edge",
        voice="v1",
        language="pt",
        machine_signature="linux-c4-r8-nmedium",
    )
    assert entry is not None
