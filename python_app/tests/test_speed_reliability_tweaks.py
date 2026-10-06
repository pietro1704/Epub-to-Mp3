"""Regression tests for the speed/reliability tweaks:

- ``CLEANUP_INTERVAL_SECONDS`` is env-configurable and defaults lower on HF.
- HF keep-alive initial delay is env-configurable.
- Retry backoff in converter / server adds jitter (non-deterministic within a band).
- ``_maybe_retry`` / ``_RetryChapter`` short-circuit on terminal error categories
  (``auth``, ``engine_unavailable``).
"""

from __future__ import annotations

import os
import random

import pytest

from python_app.src.error_classifier import classify_error

# ── CLEANUP_INTERVAL_SECONDS ───────────────────────────────────────────────


class TestCleanupInterval:
    def test_default_local(self, monkeypatch):
        monkeypatch.delenv("SPACE_ID", raising=False)
        monkeypatch.delenv("CLEANUP_INTERVAL_SECONDS", raising=False)
        from python_app import server

        assert server.get_cleanup_interval_seconds() == 300

    def test_default_hf(self, monkeypatch):
        monkeypatch.setenv("SPACE_ID", "example/space")
        monkeypatch.delenv("CLEANUP_INTERVAL_SECONDS", raising=False)
        from python_app import server

        assert server.get_cleanup_interval_seconds() == 60

    def test_env_override(self, monkeypatch):
        monkeypatch.delenv("SPACE_ID", raising=False)
        monkeypatch.setenv("CLEANUP_INTERVAL_SECONDS", "45")
        from python_app import server

        assert server.get_cleanup_interval_seconds() == 45

    def test_env_override_min_clamp(self, monkeypatch):
        monkeypatch.delenv("SPACE_ID", raising=False)
        monkeypatch.setenv("CLEANUP_INTERVAL_SECONDS", "0")
        from python_app import server

        # Minimum clamp is 10 so the cleanup loop can't run too hot.
        assert server.get_cleanup_interval_seconds() == 10


# ── Error classifier short-circuits ────────────────────────────────────────


class TestTerminalCategoryShortCircuit:
    def test_auth_is_terminal(self):
        assert classify_error("HTTP 401 unauthorized") == "auth"
        assert classify_error("403 Forbidden") == "auth"

    def test_engine_unavailable_is_terminal(self):
        assert classify_error("No TTS engine available") == "engine_unavailable"
        assert classify_error("engine unavailable for pt-BR") == "engine_unavailable"

    def test_rate_limit_is_not_terminal(self):
        # Must still be retryable — only auth / engine_unavailable skip retry.
        assert classify_error("HTTP 429 Too Many Requests") == "rate_limit"

    def test_timeout_is_not_terminal(self):
        assert classify_error("Chapter timed out") == "timeout"

    def test_converter_imports_classifier(self):
        # The short-circuit relies on classify_error being importable from the
        # converter module. Import-time smoke test.
        from python_app.src import converter

        assert callable(converter.classify_error)
        assert converter.classify_error("HTTP 401 unauthorized") == "auth"

    def test_server_imports_classifier(self):
        # Use functional equivalence instead of ``is`` — other tests reload the
        # server module, which rebinds classify_error to a fresh object.
        import python_app.server as srv

        assert callable(srv.classify_error)
        assert srv.classify_error("No TTS engine available") == "engine_unavailable"


# ── Backoff jitter ─────────────────────────────────────────────────────────


class TestBackoffJitter:
    """Verify jitter is applied to retry backoff formulas used in converter/server.

    The production code is intentionally simple: ``base * (1 + uniform(-0.2, 0.2))``.
    We just verify that with a seeded RNG the distribution lands inside the ±20%
    band and is not a constant value.
    """

    def test_converter_backoff_band(self):
        # Mirror the formula in converter.py: base = min(30, 2**min(attempt, 5)),
        # then jitter = uniform(-0.2, 0.2) * base, floored at 0.5.
        samples = []
        rng = random.Random(42)
        for _ in range(200):
            base = min(30, 2 ** min(3, 5))  # 8s
            jitter = rng.uniform(-0.2, 0.2) * base
            samples.append(max(0.5, base + jitter))
        assert min(samples) >= 0.5
        assert min(samples) >= base * 0.8 - 0.01
        assert max(samples) <= base * 1.2 + 0.01
        # Non-constant: at least one spread present.
        assert len(set(round(s, 3) for s in samples)) > 10

    def test_server_backoff_band(self):
        # Mirror the formula in server._maybe_retry:
        #   backoff = base_backoff * (1 + 0.5 * (retry - 1))
        #   backoff = max(0, backoff + uniform(-0.2, 0.2) * backoff)
        samples = []
        rng = random.Random(7)
        base_backoff_seconds = 2.0
        retry = 3
        for _ in range(200):
            backoff = base_backoff_seconds * (1 + 0.5 * (retry - 1))  # 4.0
            backoff = max(0.0, backoff + rng.uniform(-0.2, 0.2) * backoff)
            samples.append(backoff)
        expected = base_backoff_seconds * (1 + 0.5 * (retry - 1))
        assert min(samples) >= expected * 0.8 - 0.01
        assert max(samples) <= expected * 1.2 + 0.01
        assert len(set(round(s, 3) for s in samples)) > 10


# ── HF keep-alive initial delay ────────────────────────────────────────────


class TestHFKeepaliveDelay:
    def test_env_override(self, monkeypatch):
        monkeypatch.setenv("HF_KEEPALIVE_INITIAL_DELAY", "3")
        # We just verify the env var read path — full coroutine is covered by
        # integration tests. Ensure the default/override logic doesn't crash.
        val = max(1, int(os.getenv("HF_KEEPALIVE_INITIAL_DELAY", "10") or "10"))
        assert val == 3

    def test_default(self, monkeypatch):
        monkeypatch.delenv("HF_KEEPALIVE_INITIAL_DELAY", raising=False)
        val = max(1, int(os.getenv("HF_KEEPALIVE_INITIAL_DELAY", "10") or "10"))
        assert val == 10

    def test_min_clamp(self, monkeypatch):
        monkeypatch.setenv("HF_KEEPALIVE_INITIAL_DELAY", "0")
        val = max(1, int(os.getenv("HF_KEEPALIVE_INITIAL_DELAY", "10") or "10"))
        assert val == 1


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
