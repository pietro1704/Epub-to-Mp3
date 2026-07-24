"""Regression coverage for TTSFactory's engine registry (Open/Closed fix).

create_engine used to be a hardcoded if/elif chain; it now dispatches
through TTSFactory._engine_builders, a dict[str, Callable]. Adding a new
engine should mean registering a builder, not editing create_engine.
"""

import pytest

from python_app.src.tts.factory import TTSFactory


def test_engine_builders_registry_has_edge_and_piper():
    factory = TTSFactory()
    assert set(factory._engine_builders.keys()) == {"edge", "piper"}
    assert factory._engine_builders["edge"] == factory._build_edge_engine
    assert factory._engine_builders["piper"] == factory._build_piper_engine


def test_create_engine_dispatches_through_registry(monkeypatch):
    factory = TTSFactory()
    calls = []
    factory._engine_builders["edge"] = lambda config: calls.append(config) or "sentinel"

    class FakeConfig:
        engine = "edge"

    result = factory.create_engine(FakeConfig())
    assert result == "sentinel"
    assert len(calls) == 1


def test_create_engine_raises_for_unregistered_engine():
    factory = TTSFactory()

    class FakeConfig:
        engine = "some_future_engine"
        enable_character_voices = False
        narrator_voice = None
        character_voice = None

    with pytest.raises(ValueError, match="Unsupported engine"):
        factory.create_engine(FakeConfig())


def test_registering_a_new_engine_requires_no_dispatch_edit():
    """Open/Closed check: adding an engine is a dict insert, not a branch."""
    factory = TTSFactory()
    sentinel_engine = object()
    factory._engine_builders["kokoro"] = lambda config: sentinel_engine

    class FakeConfig:
        engine = "kokoro"

    assert factory.create_engine(FakeConfig()) is sentinel_engine
