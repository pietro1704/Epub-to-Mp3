# -*- coding: utf-8 -*-
"""Tests for _RetryMixin — classify_failure_reason, should_flag_slowdown, checkpoint I/O."""

from __future__ import annotations

import json

from python_app.src._retry_mixin import _RetryMixin

# ---------------------------------------------------------------------------
# Minimal concrete subclass so we can instantiate the mixin
# ---------------------------------------------------------------------------


class _ConcreteRetry(_RetryMixin):
    """Minimal concrete class that satisfies _save_failure_checkpoint's self.verbose."""

    def __init__(self, verbose: bool = False):
        self.verbose = verbose


# ---------------------------------------------------------------------------
# _classify_failure_reason
# ---------------------------------------------------------------------------


class TestClassifyFailureReason:
    def test_none_returns_unknown(self):
        assert _RetryMixin._classify_failure_reason(None) == "unknown"

    def test_empty_string_returns_unknown(self):
        assert _RetryMixin._classify_failure_reason("") == "unknown"

    def test_whitespace_returns_unknown(self):
        assert _RetryMixin._classify_failure_reason("   ") == "unknown"

    def test_unrecognised_message_returns_unknown(self):
        assert _RetryMixin._classify_failure_reason("Something odd happened") == "unknown"

    # auth
    def test_unauthorized(self):
        assert _RetryMixin._classify_failure_reason("401 Unauthorized") == "auth"

    def test_forbidden_403(self):
        assert _RetryMixin._classify_failure_reason("403 Forbidden") == "auth"

    def test_auth_keyword(self):
        assert _RetryMixin._classify_failure_reason("Authentication failed: auth error") == "auth"

    # throttle
    def test_429_status(self):
        assert _RetryMixin._classify_failure_reason("HTTP 429 Too Many Requests") == "throttle"

    def test_rate_limit(self):
        assert _RetryMixin._classify_failure_reason("rate limit exceeded") == "throttle"

    def test_rate_limit_underscore(self):
        assert _RetryMixin._classify_failure_reason("rate_limit hit") == "throttle"

    def test_too_many_requests(self):
        assert _RetryMixin._classify_failure_reason("too many requests from this IP") == "throttle"

    def test_throttle(self):
        assert _RetryMixin._classify_failure_reason("Request throttled by server") == "throttle"

    def test_quota_exceeded(self):
        assert _RetryMixin._classify_failure_reason("Daily quota exceeded") == "throttle"

    # no_audio
    def test_noaudio(self):
        assert _RetryMixin._classify_failure_reason("noaudio error") == "no_audio"

    def test_no_audio_underscore(self):
        assert _RetryMixin._classify_failure_reason("no_audio received") == "no_audio"

    def test_noaudioreceived(self):
        assert _RetryMixin._classify_failure_reason("NoAudioReceived from Edge") == "no_audio"

    # network
    def test_ssl_error(self):
        assert _RetryMixin._classify_failure_reason("SSL handshake failed") == "network"

    def test_certificate_error(self):
        assert _RetryMixin._classify_failure_reason("certificate verify failed") == "network"

    def test_dns_error(self):
        assert _RetryMixin._classify_failure_reason("DNS resolution failed") == "network"

    def test_connector_error(self):
        assert _RetryMixin._classify_failure_reason("connector error on host") == "network"

    def test_connection_refused(self):
        assert _RetryMixin._classify_failure_reason("connection refused to 127.0.0.1") == "network"

    def test_connection_generic(self):
        assert _RetryMixin._classify_failure_reason("connection reset by peer") == "network"

    # transient
    def test_timeout(self):
        assert _RetryMixin._classify_failure_reason("Chapter timed out after 90s") == "transient"

    def test_timed_out(self):
        assert _RetryMixin._classify_failure_reason("Synthesis timed out") == "transient"

    def test_503(self):
        assert _RetryMixin._classify_failure_reason("503 service_unavailable") == "transient"

    # case insensitivity
    def test_case_insensitive_auth(self):
        assert _RetryMixin._classify_failure_reason("UNAUTHORIZED access") == "auth"

    def test_case_insensitive_throttle(self):
        assert _RetryMixin._classify_failure_reason("RATE LIMIT hit") == "throttle"


# ---------------------------------------------------------------------------
# _should_flag_slowdown
# ---------------------------------------------------------------------------


class TestShouldFlagSlowdown:
    def test_none_returns_false(self):
        assert _RetryMixin._should_flag_slowdown(None) is False

    def test_empty_string_returns_false(self):
        assert _RetryMixin._should_flag_slowdown("") is False

    def test_timeout_keyword(self):
        assert _RetryMixin._should_flag_slowdown("Chapter timeout after 90s") is True

    def test_rate_keyword(self):
        assert _RetryMixin._should_flag_slowdown("rate limit exceeded") is True

    def test_limit_keyword(self):
        assert _RetryMixin._should_flag_slowdown("daily limit reached") is True

    def test_throttle_keyword(self):
        assert _RetryMixin._should_flag_slowdown("throttle applied") is True

    def test_quota_keyword(self):
        assert _RetryMixin._should_flag_slowdown("quota exceeded today") is True

    def test_unrelated_error(self):
        assert _RetryMixin._should_flag_slowdown("FileNotFoundError: foo.mp3") is False

    def test_case_insensitive(self):
        assert _RetryMixin._should_flag_slowdown("TIMEOUT error") is True


# ---------------------------------------------------------------------------
# Checkpoint save / load / clear cycle
# ---------------------------------------------------------------------------


class TestFailureCheckpoint:
    def test_checkpoint_path_none_when_no_dir(self):
        mixin = _ConcreteRetry()
        assert mixin._failure_checkpoint_path(None) is None

    def test_checkpoint_path_returns_file(self, tmp_path):
        mixin = _ConcreteRetry()
        result = mixin._failure_checkpoint_path(tmp_path)
        assert result is not None
        assert result.name == "_failure_checkpoint.json"
        assert result.parent == tmp_path

    def test_load_returns_empty_when_no_dir(self):
        mixin = _ConcreteRetry()
        assert mixin._load_failure_checkpoint(None) == {}

    def test_load_returns_empty_when_file_missing(self, tmp_path):
        mixin = _ConcreteRetry()
        result = mixin._load_failure_checkpoint(tmp_path)
        assert result == {}

    def test_save_and_load_round_trip(self, tmp_path):
        mixin = _ConcreteRetry()
        mixin._save_failure_checkpoint(
            tmp_path,
            failed_chapters=["1", "3"],
            edge_blocked_chapters=["2"],
        )
        payload = mixin._load_failure_checkpoint(tmp_path)
        assert payload["failed_chapters"] == ["1", "3"]
        assert payload["edge_blocked_chapters"] == ["2"]
        assert "updated_at" in payload

    def test_save_deduplicates_and_sorts(self, tmp_path):
        mixin = _ConcreteRetry()
        mixin._save_failure_checkpoint(
            tmp_path,
            failed_chapters=["3", "1", "3", "1"],
        )
        payload = mixin._load_failure_checkpoint(tmp_path)
        assert payload["failed_chapters"] == ["1", "3"]

    def test_save_ignores_empty_strings(self, tmp_path):
        mixin = _ConcreteRetry()
        mixin._save_failure_checkpoint(
            tmp_path,
            failed_chapters=["", " ", "5"],
        )
        payload = mixin._load_failure_checkpoint(tmp_path)
        assert payload["failed_chapters"] == ["5"]

    def test_save_with_no_output_dir(self):
        mixin = _ConcreteRetry()
        # Should not raise
        mixin._save_failure_checkpoint(None, failed_chapters=["1"])

    def test_clear_removes_file(self, tmp_path):
        mixin = _ConcreteRetry()
        mixin._save_failure_checkpoint(tmp_path, failed_chapters=["1"])
        checkpoint_path = mixin._failure_checkpoint_path(tmp_path)
        assert checkpoint_path is not None and checkpoint_path.exists()
        mixin._clear_failure_checkpoint(tmp_path)
        assert not checkpoint_path.exists()

    def test_clear_no_dir_does_not_raise(self):
        mixin = _ConcreteRetry()
        mixin._clear_failure_checkpoint(None)  # must not raise

    def test_clear_missing_file_does_not_raise(self, tmp_path):
        mixin = _ConcreteRetry()
        mixin._clear_failure_checkpoint(tmp_path)  # file was never created — must not raise

    def test_load_corrupt_json_returns_empty(self, tmp_path):
        mixin = _ConcreteRetry()
        checkpoint_path = tmp_path / "_failure_checkpoint.json"
        checkpoint_path.write_text("NOT VALID JSON", encoding="utf-8")
        result = mixin._load_failure_checkpoint(tmp_path)
        assert result == {}

    def test_load_non_dict_json_returns_empty(self, tmp_path):
        mixin = _ConcreteRetry()
        checkpoint_path = tmp_path / "_failure_checkpoint.json"
        checkpoint_path.write_text(json.dumps([1, 2, 3]), encoding="utf-8")
        result = mixin._load_failure_checkpoint(tmp_path)
        assert result == {}

    def test_save_includes_resume_chunks_when_chunk_dir_exists(self, tmp_path):
        mixin = _ConcreteRetry()
        # Create a fake chunks directory structure
        chapter_dir = tmp_path / "chunks" / "chapter_1"
        chapter_dir.mkdir(parents=True)
        (chapter_dir / "chunk_0.mp3").write_bytes(b"")
        (chapter_dir / "chunk_1.mp3").write_bytes(b"")

        mixin._save_failure_checkpoint(tmp_path, failed_chapters=["1"])
        payload = mixin._load_failure_checkpoint(tmp_path)
        assert "chapter_1" in payload["resume_chunks"]
        assert payload["resume_chunks"]["chapter_1"]["chunk_files"] == 2


# ---------------------------------------------------------------------------
# _scaled_quick_timeout — size-aware retry timeout
# ---------------------------------------------------------------------------


class TestScaledQuickTimeout:
    def test_zero_chars_returns_base(self):
        assert _RetryMixin._scaled_quick_timeout(90, 0, "edge") == 90

    def test_negative_chars_returns_base(self):
        assert _RetryMixin._scaled_quick_timeout(90, -500, "edge") == 90

    def test_below_reference_returns_base_edge(self):
        # 15k reference for edge → 10k stays at base.
        assert _RetryMixin._scaled_quick_timeout(90, 10_000, "edge") == 90

    def test_at_reference_returns_base_piper(self):
        # 8k reference for piper.
        assert _RetryMixin._scaled_quick_timeout(360, 8_000, "piper") == 360

    def test_scales_above_reference_edge(self):
        # Edge at 30k = 2× ref → overflow 1.0 → scale 2.3× ≈ 207s.
        result = _RetryMixin._scaled_quick_timeout(90, 30_000, "edge")
        assert 200 <= result <= 215

    def test_scales_above_reference_piper(self):
        # Piper at 16k = 2× ref → overflow 1.0 → scale 2.3× ≈ 828s.
        result = _RetryMixin._scaled_quick_timeout(360, 16_000, "piper")
        assert 820 <= result <= 835

    def test_caps_at_3x(self):
        # Very long chapter must not exceed 3× base.
        result = _RetryMixin._scaled_quick_timeout(90, 1_000_000, "edge")
        assert result == 270  # 3 × 90

    def test_unknown_engine_uses_generic_reference(self):
        # Fallback reference is 12k for unknown engines.
        assert _RetryMixin._scaled_quick_timeout(240, 10_000, "kokoro_xl") == 240

    def test_base_is_floored(self):
        # Tiny base values get a minimum floor of 10 before scaling.
        assert _RetryMixin._scaled_quick_timeout(5, 10_000, "edge") == 10

    def test_engine_name_case_insensitive(self):
        a = _RetryMixin._scaled_quick_timeout(90, 30_000, "EDGE")
        b = _RetryMixin._scaled_quick_timeout(90, 30_000, "edge")
        assert a == b
