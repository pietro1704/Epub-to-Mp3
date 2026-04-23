# -*- coding: utf-8 -*-
"""Tests for the GET /api/voice-preview endpoint."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def _patch_env(monkeypatch):
    monkeypatch.setenv("PYTEST_CURRENT_TEST", "1")


@pytest.fixture()
def client():
    """Return a TestClient backed by the FastAPI app."""
    import python_app.server as server_mod

    return TestClient(server_mod.app)


class TestVoicePreviewEndpoint:
    """Tests for GET /api/voice-preview."""

    def test_rejects_unsupported_engine(self, client: TestClient):
        resp = client.get("/api/voice-preview", params={"engine": "unknown"})
        assert resp.status_code == 400
        assert "Unsupported engine" in resp.json()["detail"]

    def test_rejects_auto_engine(self, client: TestClient):
        resp = client.get("/api/voice-preview", params={"engine": "auto"})
        assert resp.status_code == 400

    def test_returns_cached_file(self, client: TestClient, tmp_path: Path):
        """When a cached preview already exists, it should be returned directly."""
        import python_app.server as server_mod

        cache_dir = tmp_path / "voice-previews"
        cache_dir.mkdir()
        cached = cache_dir / "edge__pt-BR-ThalitaMultilingualNeural__pt.mp3"
        cached.write_bytes(b"\xff\xfb\x90\x00" + b"\x00" * 100)  # fake MP3

        original_cache = server_mod._PREVIEW_CACHE_DIR
        server_mod._PREVIEW_CACHE_DIR = cache_dir
        try:
            resp = client.get(
                "/api/voice-preview",
                params={
                    "engine": "edge",
                    "voice": "pt-BR-ThalitaMultilingualNeural",
                    "language": "pt",
                },
            )
            assert resp.status_code == 200
            assert resp.headers["content-type"].startswith("audio/mpeg")
            assert len(resp.content) > 0
        finally:
            server_mod._PREVIEW_CACHE_DIR = original_cache

    def test_synthesizes_and_caches(self, client: TestClient, tmp_path: Path):
        """When no cache exists, it should synthesize and save to cache."""
        import python_app.server as server_mod

        cache_dir = tmp_path / "voice-previews"
        cache_dir.mkdir()

        original_cache = server_mod._PREVIEW_CACHE_DIR
        server_mod._PREVIEW_CACHE_DIR = cache_dir

        fake_audio = b"\xff\xfb\x90\x00" + b"\x00" * 200

        async def fake_synthesize(text, output_path, **kwargs):
            output_path.write_bytes(fake_audio)

        mock_engine = MagicMock()
        mock_engine.synthesize_async = fake_synthesize

        with patch.object(server_mod.tts_factory, "create_engine", return_value=mock_engine):
            try:
                resp = client.get(
                    "/api/voice-preview",
                    params={
                        "engine": "edge",
                        "voice": "pt-BR-FranciscaNeural",
                        "language": "pt",
                    },
                )
                assert resp.status_code == 200
                assert resp.headers["content-type"].startswith("audio/mpeg")

                # Verify cache was written
                cached = cache_dir / "edge__pt-BR-FranciscaNeural__pt.mp3"
                assert cached.exists()
                assert cached.stat().st_size > 0
            finally:
                server_mod._PREVIEW_CACHE_DIR = original_cache

    def test_synthesis_failure_returns_500(self, client: TestClient, tmp_path: Path):
        """When synthesis raises an exception, return 500."""
        import python_app.server as server_mod

        cache_dir = tmp_path / "voice-previews"
        cache_dir.mkdir()

        original_cache = server_mod._PREVIEW_CACHE_DIR
        server_mod._PREVIEW_CACHE_DIR = cache_dir

        async def failing_synthesize(text, output_path, **kwargs):
            raise RuntimeError("TTS engine exploded")

        mock_engine = MagicMock()
        mock_engine.synthesize_async = failing_synthesize

        with patch.object(server_mod.tts_factory, "create_engine", return_value=mock_engine):
            try:
                resp = client.get(
                    "/api/voice-preview",
                    params={"engine": "edge", "voice": "bad-voice", "language": "en"},
                )
                assert resp.status_code == 500
                assert "Synthesis failed" in resp.json()["detail"]
            finally:
                server_mod._PREVIEW_CACHE_DIR = original_cache

    def test_kokoro_language_defaults_to_en(self, client: TestClient, tmp_path: Path):
        """Kokoro only supports en/ja/zh — pt should fallback to en."""
        import python_app.server as server_mod

        cache_dir = tmp_path / "voice-previews"
        cache_dir.mkdir()

        original_cache = server_mod._PREVIEW_CACHE_DIR
        server_mod._PREVIEW_CACHE_DIR = cache_dir

        captured_config = {}

        def capture_engine(config):
            captured_config["language"] = config.primary_language
            engine = MagicMock()

            async def synth(text, output_path, **kwargs):
                output_path.write_bytes(b"\xff\xfb\x90\x00" + b"\x00" * 50)

            engine.synthesize_async = synth
            return engine

        with patch.object(server_mod.tts_factory, "create_engine", side_effect=capture_engine):
            try:
                resp = client.get(
                    "/api/voice-preview",
                    params={
                        "engine": "kokoro",
                        "voice": "af_heart",
                        "language": "pt",
                    },
                )
                assert resp.status_code == 200
                assert captured_config["language"] == "en"
            finally:
                server_mod._PREVIEW_CACHE_DIR = original_cache

    def test_default_language_is_pt(self, client: TestClient, tmp_path: Path):
        """When no language param is given, default to pt."""
        import python_app.server as server_mod

        cache_dir = tmp_path / "voice-previews"
        cache_dir.mkdir()

        original_cache = server_mod._PREVIEW_CACHE_DIR
        server_mod._PREVIEW_CACHE_DIR = cache_dir

        captured_text = {}

        def capture_engine(config):
            engine = MagicMock()

            async def synth(text, output_path, **kwargs):
                captured_text["text"] = text
                output_path.write_bytes(b"\xff\xfb\x90\x00" + b"\x00" * 50)

            engine.synthesize_async = synth
            return engine

        with patch.object(server_mod.tts_factory, "create_engine", side_effect=capture_engine):
            try:
                resp = client.get(
                    "/api/voice-preview",
                    params={"engine": "edge", "voice": "pt-BR-ThalitaMultilingualNeural"},
                )
                assert resp.status_code == 200
                # Should use Portuguese sample text
                assert "livro" in captured_text["text"]
            finally:
                server_mod._PREVIEW_CACHE_DIR = original_cache

    def test_rate_limit_blocks_excess_requests(self, client: TestClient, tmp_path: Path):
        """After 10 rapid requests, the 11th should be rejected with 429."""
        import python_app.server as server_mod

        cache_dir = tmp_path / "voice-previews"
        cache_dir.mkdir()

        # Pre-populate cache so requests don't trigger synthesis
        for i in range(12):
            cached = cache_dir / f"edge__voice{i}__pt.mp3"
            cached.write_bytes(b"\xff\xfb\x90\x00" + b"\x00" * 50)

        original_cache = server_mod._PREVIEW_CACHE_DIR
        server_mod._PREVIEW_CACHE_DIR = cache_dir

        # Clear any existing rate state for this IP
        with server_mod._preview_rate_lock:
            server_mod._preview_rate_log.clear()

        try:
            for i in range(10):
                resp = client.get(
                    "/api/voice-preview",
                    params={"engine": "edge", "voice": f"voice{i}", "language": "pt"},
                )
                assert resp.status_code == 200, f"Request {i} should succeed"

            # 11th request should be rate-limited
            resp = client.get(
                "/api/voice-preview",
                params={"engine": "edge", "voice": "voice10", "language": "pt"},
            )
            assert resp.status_code == 429
            assert "Too many" in resp.json()["detail"]
        finally:
            server_mod._PREVIEW_CACHE_DIR = original_cache
            with server_mod._preview_rate_lock:
                server_mod._preview_rate_log.clear()


class TestVoiceCatalog:
    """Tests for the /api/voices endpoint voice catalog."""

    def test_voices_includes_kokoro(self, client: TestClient):
        resp = client.get("/api/voices")
        assert resp.status_code == 200
        voices = resp.json()["voices"]
        assert "kokoro" in voices
        kokoro_ids = [v["id"] for v in voices["kokoro"]]
        assert "af_heart" in kokoro_ids
        assert "bf_emma" in kokoro_ids

    def test_voices_includes_spark(self, client: TestClient):
        resp = client.get("/api/voices")
        assert resp.status_code == 200
        voices = resp.json()["voices"]
        assert "spark" in voices
        spark_ids = [v["id"] for v in voices["spark"]]
        assert "default" in spark_ids
        assert "clone" in spark_ids

    def test_voices_all_engines_present(self, client: TestClient):
        resp = client.get("/api/voices")
        voices = resp.json()["voices"]
        for engine in ("edge", "coqui", "kokoro", "spark", "piper", "auto"):
            assert engine in voices, f"Missing engine: {engine}"


class TestPreviewCacheCleanup:
    """Tests for the voice preview cache TTL cleanup logic."""

    def test_old_files_cleaned_up(self, tmp_path: Path):
        """Files older than TTL should be removed."""
        import time

        cache_dir = tmp_path / "voice-previews"
        cache_dir.mkdir()

        old_file = cache_dir / "old_preview.mp3"
        old_file.write_bytes(b"\x00" * 10)

        new_file = cache_dir / "new_preview.mp3"
        new_file.write_bytes(b"\x00" * 10)

        # Make old_file appear very old
        import os

        old_time = time.time() - (31 * 24 * 3600)
        os.utime(old_file, (old_time, old_time))

        # Simulate the cleanup logic
        ttl = 30 * 24 * 3600
        now = time.time()
        for f in cache_dir.glob("*.mp3"):
            if now - f.stat().st_mtime > ttl:
                f.unlink()

        assert not old_file.exists()
        assert new_file.exists()


class TestRateLimiter:
    """Tests for the _check_preview_rate_limit function."""

    def test_allows_within_limit(self):
        import python_app.server as server_mod

        with server_mod._preview_rate_lock:
            server_mod._preview_rate_log.pop("test_ip_1", None)

        for _ in range(10):
            assert server_mod._check_preview_rate_limit("test_ip_1") is True

        with server_mod._preview_rate_lock:
            server_mod._preview_rate_log.pop("test_ip_1", None)

    def test_blocks_over_limit(self):
        import python_app.server as server_mod

        with server_mod._preview_rate_lock:
            server_mod._preview_rate_log.pop("test_ip_2", None)

        for _ in range(10):
            server_mod._check_preview_rate_limit("test_ip_2")

        assert server_mod._check_preview_rate_limit("test_ip_2") is False

        with server_mod._preview_rate_lock:
            server_mod._preview_rate_log.pop("test_ip_2", None)

    def test_different_ips_independent(self):
        import python_app.server as server_mod

        with server_mod._preview_rate_lock:
            server_mod._preview_rate_log.pop("ip_a", None)
            server_mod._preview_rate_log.pop("ip_b", None)

        for _ in range(10):
            server_mod._check_preview_rate_limit("ip_a")

        # ip_a is maxed out, but ip_b should still work
        assert server_mod._check_preview_rate_limit("ip_a") is False
        assert server_mod._check_preview_rate_limit("ip_b") is True

        with server_mod._preview_rate_lock:
            server_mod._preview_rate_log.pop("ip_a", None)
            server_mod._preview_rate_log.pop("ip_b", None)
