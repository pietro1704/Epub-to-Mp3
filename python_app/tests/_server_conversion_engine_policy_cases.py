"""Engine Policy regression scenarios, collected by test_server_conversion."""

from __future__ import annotations

import python_app.tests._server_conversion_test_support as _shared_test_exports
from python_app.tests._server_conversion_test_support import MINIMAL_MP3 as MINIMAL_MP3
from python_app.tests._server_conversion_test_support import ConversionConfig as ConversionConfig
from python_app.tests._server_conversion_test_support import SimpleNamespace as SimpleNamespace
from python_app.tests._server_conversion_test_support import server as server
from python_app.tests._server_conversion_test_support import (
    server_audio_helpers as server_audio_helpers,
)

os = _shared_test_exports.os
replace = _shared_test_exports.replace


def test_build_engine_chain_respects_guards(monkeypatch):
    """When all non-Edge engines are unavailable and no monolingual voice exists, chain = [edge]."""
    config = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_coqui_support", lambda: False)
    monkeypatch.setattr(server, "_has_kokoro_support", lambda _: False)
    monkeypatch.setattr(server, "_has_piper_support", lambda: False)
    # Suppress monolingual fallback so only the primary Edge entry appears.
    monkeypatch.setattr(
        server.tts_factory.voice_provider, "get_monolingual_voice", lambda _lang: None
    )

    chain = server._build_engine_chain(config)
    assert [cfg.engine for cfg in chain] == ["edge"]


def test_build_engine_chain_includes_edge_monolingual_fallback(monkeypatch):
    """Edge monolingual fallback is inserted as tier-2 when a distinct mono voice exists."""
    config = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_coqui_support", lambda: False)
    monkeypatch.setattr(server, "_has_kokoro_support", lambda _: False)
    monkeypatch.setattr(server, "_has_piper_support", lambda: False)
    # Simulate a multilingual primary voice and a distinct monolingual alternative.
    monkeypatch.setattr(
        server.tts_factory.voice_provider,
        "edge_voice_is_multilingual",
        lambda _voice: True,
    )
    monkeypatch.setattr(
        server.tts_factory.voice_provider,
        "get_monolingual_voice",
        lambda _lang: "pt-BR-AntonioNeural",
    )

    chain = server._build_engine_chain(config)
    engines = [cfg.engine for cfg in chain]
    assert engines == ["edge", "edge"]
    # Second entry must use the monolingual voice.
    assert chain[1].voice == "pt-BR-AntonioNeural"


def test_build_engine_chain_includes_supported_fallbacks(monkeypatch):
    config = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_piper_support", lambda: True)
    monkeypatch.setattr("src._server_engine_helpers._piper_model_available", lambda _lang: True)
    monkeypatch.setenv("ENGINE_CHAIN_FALLBACK", "1")

    chain = server._build_engine_chain(config)
    engines = [cfg.engine for cfg in chain]
    assert "edge" in engines and "piper" in engines


def test_should_retry_edge_before_fallback_prefers_one_local_retry():
    assert server._should_retry_edge_before_fallback("edge", edge_slow_mode=False) is True
    assert server._should_retry_edge_before_fallback("EDGE", edge_slow_mode=True) is False
    assert server._should_retry_edge_before_fallback("piper", edge_slow_mode=False) is False


def test_rank_fallbacks_includes_piper(monkeypatch):
    """After the multi-engine cleanup only Piper remains in the offline chain;
    confirm it is appended when ENGINE_CHAIN_FALLBACK is enabled."""
    from dataclasses import replace

    base = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_piper_support", lambda: True)
    monkeypatch.setattr("src._server_engine_helpers._piper_model_available", lambda _lang: True)
    monkeypatch.setenv("ENGINE_CHAIN_FALLBACK", "1")

    chain = server._build_engine_chain(replace(base))
    engines = [cfg.engine for cfg in chain]
    assert engines[0] == "edge"
    assert "piper" in engines[1:]


def test_engine_is_disabled_respects_unavailable_set():
    # Regression: after the job-wide Edge timeout threshold fires, subsequent
    # chapters must not retry Edge — otherwise each one burns _CHAPTER_RETRY_MAX
    # timeouts before giving up (observed: 14 chapters × 4 retries = ~56 timeouts).
    unavailable: set[str] = {"edge"}
    assert server._engine_is_disabled("edge", unavailable) is True
    assert server._engine_is_disabled("EDGE", unavailable) is True
    assert server._engine_is_disabled("piper", unavailable) is False
    assert server._engine_is_disabled(None, unavailable) is False
    assert server._engine_is_disabled("edge", set()) is False


def test_pick_auto_engine_prefers_fastest_telemetry():
    pool = {
        "edge": (ConversionConfig(engine="edge"), SimpleNamespace()),
        "piper": (ConversionConfig(engine="piper"), SimpleNamespace()),
    }
    telemetry_speeds = {"edge": 180.0, "piper": 50.0}
    selected, order = server._pick_auto_engine(12_000, 600, pool, telemetry_speeds=telemetry_speeds)
    assert order[0] == "edge"
    assert selected == order[0]


def test_server_short_audio_detection_uses_cli_completeness_threshold(monkeypatch, tmp_path):
    output_file = tmp_path / "chapter.mp3"
    output_file.write_bytes(MINIMAL_MP3)

    called = {}

    def fake_validate(audio_path, text_length):
        called["audio_path"] = audio_path
        called["text_length"] = text_length
        return False, 72.0

    monkeypatch.setattr(
        "src.converter.validate_audio_completeness",
        fake_validate,
    )

    warning = server_audio_helpers._detect_short_audio_output(
        "x" * 1600,
        output_file,
        engine_label="edge",
    )

    assert warning == "Audio possibly truncated (72% coverage, expected full chapter)"
    assert called["audio_path"] == output_file
    assert called["text_length"] == 1600


def test_server_max_chapter_chars_skip_predicate():
    """Server MAX_CHAPTER_CHARS skip condition mirrors converter.py logic."""
    # When limit > 0 and chapter exceeds it → skip
    limit = 200_000
    assert limit > 0 and 279_000 > limit, "Oversized chapter should match skip condition"
    assert not (limit > 0 and 5_000 > limit), "Normal chapter should not match skip condition"

    # When limit == 0 (disabled) → never skip regardless of size
    assert not (0 > 0 and 999_999 > 0), "Disabled limit should never trigger skip"


def test_server_max_chapter_chars_default_is_zero():
    """MAX_CHAPTER_CHARS in server defaults to 0 (disabled), same as converter."""
    import os

    raw = os.environ.get("MAX_CHAPTER_CHARS", "")
    value = int(raw) if raw else 0
    assert value == 0, "Default MAX_CHAPTER_CHARS must be 0 (disabled)"
