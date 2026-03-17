"""Tests for error_classifier — stable error category mapping."""

from python_app.src.error_classifier import classify_error


class TestClassifyError:
    # ── rate_limit ─────────────────────────────────────────────────────
    def test_429_status(self):
        assert classify_error("HTTP 429 Too Many Requests") == "rate_limit"

    def test_rate_limit_text(self):
        assert classify_error("edge: rate limit exceeded") == "rate_limit"

    def test_throttle(self):
        assert classify_error("Request throttled by server") == "rate_limit"

    def test_quota(self):
        assert classify_error("Daily quota exceeded") == "rate_limit"

    def test_too_many_requests(self):
        assert classify_error("too many requests from this IP") == "rate_limit"

    # ── timeout ────────────────────────────────────────────────────────
    def test_timeout_word(self):
        assert classify_error("Chapter timed out after 120s") == "timeout"

    def test_timed_out(self):
        assert classify_error("Synthesis timed out") == "timeout"

    def test_503_service_unavailable(self):
        assert classify_error("503 Service Unavailable") == "timeout"

    def test_stall(self):
        assert classify_error("Engine stalled for 60s") == "timeout"

    # ── network ────────────────────────────────────────────────────────
    def test_ssl_error(self):
        assert classify_error("SSL handshake failed") == "network"

    def test_connection_refused(self):
        assert classify_error("connection refused to 127.0.0.1:5000") == "network"

    def test_dns_error(self):
        assert classify_error("DNS name resolution failed") == "network"

    def test_connection_reset(self):
        assert classify_error("Connection reset by peer") == "network"

    # ── engine_unavailable ─────────────────────────────────────────────
    def test_no_engine(self):
        assert classify_error("No TTS engine available") == "engine_unavailable"

    def test_engine_unavailable(self):
        assert classify_error("Engine edge unavailable after fallback") == "engine_unavailable"

    def test_no_engine_auto_mode(self):
        assert classify_error("No engine available in automatic mode") == "engine_unavailable"

    # ── incomplete_segments ────────────────────────────────────────────
    def test_incomplete_segments(self):
        assert classify_error("Incomplete segments detected") == "incomplete_segments"

    def test_segment_failure(self):
        assert classify_error("Edge-TTS segment failure #3") == "incomplete_segments"

    def test_segment_count(self):
        assert classify_error("Segment count mismatch: expected 5, got 3") == "incomplete_segments"

    # ── audio_truncation ───────────────────────────────────────────────
    def test_truncated(self):
        assert (
            classify_error("Audio possibly truncated (got 40s, expected 90s)") == "audio_truncation"
        )

    def test_too_short(self):
        assert classify_error("audio too short for chapter") == "audio_truncation"

    def test_completion_ratio(self):
        assert classify_error("completion ratio 0.45 below expected 0.80") == "audio_truncation"

    # ── invalid_audio ──────────────────────────────────────────────────
    def test_invalid_audio(self):
        assert classify_error("Invalid audio output") == "invalid_audio"

    def test_empty_audio(self):
        assert classify_error("empty audio file produced") == "invalid_audio"

    def test_zero_duration(self):
        assert classify_error("zero-duration MP3 produced") == "invalid_audio"

    # ── cancelled ──────────────────────────────────────────────────────
    def test_cancelled(self):
        assert classify_error("Cancelled by user") == "cancelled"

    def test_cancel_requested(self):
        assert classify_error("cancel requested mid-chapter") == "cancelled"

    # ── file_not_found ─────────────────────────────────────────────────
    def test_file_not_found(self):
        assert classify_error("Edge TTS did not create an audio file") == "file_not_found"

    def test_no_such_file(self):
        assert classify_error("No such file or directory") == "file_not_found"

    # ── auth ───────────────────────────────────────────────────────────
    def test_401(self):
        assert classify_error("401 Unauthorized") == "auth"

    def test_403(self):
        assert classify_error("403 Forbidden") == "auth"

    def test_unauthorized(self):
        assert classify_error("Authentication failed: unauthorized") == "auth"

    # ── unknown ────────────────────────────────────────────────────────
    def test_empty_string(self):
        assert classify_error("") == "unknown"

    def test_none_like_empty(self):
        assert classify_error("   ") == "unknown"

    def test_unrecognised_message(self):
        assert classify_error("Something went completely sideways") == "unknown"

    # ── priority ordering ──────────────────────────────────────────────
    def test_cancelled_before_network(self):
        # "cancel" should win over any network keywords
        assert classify_error("Connection cancelled by user") == "cancelled"

    def test_rate_limit_before_timeout(self):
        # 429 messages sometimes contain timeout-adjacent language
        assert classify_error("429 rate limit: retry after timeout") == "rate_limit"
