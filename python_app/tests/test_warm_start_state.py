"""Warm-start extraction preserves aging, engine identity and disabled behavior."""

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from src import _engine_selection_mixin as selection


class _Host(selection._EngineSelectionMixin):
    def __init__(self, path):
        self._warm_start_path = path
        self._warm_start_enabled = True
        self._warm_start_ttl_seconds = 60.0

    def _runtime_tuning_key(self, config, engine):
        return {"engine": engine, "voice": config.voice, "language": "pt-BR", "machine_signature": "fixture"}


def test_warm_start_roundtrip_keeps_voice_and_engine_identity(tmp_path, monkeypatch):
    host = _Host(tmp_path / "warm.json")
    monkeypatch.setattr(selection.time, "time", lambda: 1000.0)
    host._mark_warm_start_ready(SimpleNamespace(voice="first"), "piper")
    assert host._is_warm_start_fresh(SimpleNamespace(voice="first"), "piper")
    assert not host._is_warm_start_fresh(SimpleNamespace(voice="second"), "piper")
    assert not host._is_warm_start_fresh(SimpleNamespace(voice="first"), "edge")
    payload = json.loads(host._warm_start_path.read_text())
    assert list(payload["entries"]) == ["piper|first|pt-BR|fixture"]


def test_expired_or_invalid_records_are_pruned_through_facade_save_callback(tmp_path, monkeypatch):
    host = _Host(tmp_path / "warm.json")
    host._warm_start_path.write_text(json.dumps({
        "ttl_seconds": 60, "entries": {"fresh": {"ts": 1190}, "old": {"ts": 1100}, "bad": "invalid"},
    }))
    host._save_warm_start_state = Mock()
    monkeypatch.setattr(selection.time, "time", lambda: 1200.0)
    assert host._load_warm_start_state() == {"fresh": {"ts": 1190.0}}
    host._save_warm_start_state.assert_called_once_with({"fresh": {"ts": 1190.0}})


def test_disabled_host_does_not_require_path_or_ttl_fields():
    host = object.__new__(_Host)
    host._warm_start_enabled = False
    assert host._load_warm_start_state() == {}
    host._save_warm_start_state({})
    assert not host._is_warm_start_fresh(None, "piper")


def test_malformed_state_is_best_effort_but_cancellation_propagates(tmp_path, monkeypatch):
    host = _Host(tmp_path / "warm.json")
    host._warm_start_path.write_text("not-json")
    assert host._load_warm_start_state() == {}
    with monkeypatch.context() as context:
        context.setattr(Path, "read_text", Mock(side_effect=KeyboardInterrupt))
        with pytest.raises(KeyboardInterrupt):
            host._load_warm_start_state()
