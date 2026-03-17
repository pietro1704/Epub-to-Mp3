"""Tests for session_logger — persistent conversion session log."""

import json

import pytest

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def tmp_logs_dir(tmp_path, monkeypatch):
    """Redirect LOGS_DIR and _LOG_FILE to a temp directory for each test."""
    import python_app.src.session_logger as sl

    log_file = tmp_path / "conversions.jsonl"
    monkeypatch.setattr(sl, "_LOG_FILE", log_file)
    return tmp_path


# ---------------------------------------------------------------------------
# log_session
# ---------------------------------------------------------------------------


class TestLogSession:
    def test_creates_file_on_first_write(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        assert not _LOG_FILE.exists()
        log_session(book_title="Test Book")
        assert _LOG_FILE.exists()

    def test_appends_valid_json_lines(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        log_session(book_title="Book A", outcome="success")
        log_session(book_title="Book B", outcome="failed")

        lines = _LOG_FILE.read_text(encoding="utf-8").strip().splitlines()
        assert len(lines) == 2
        r0 = json.loads(lines[0])
        r1 = json.loads(lines[1])
        assert r0["book_title"] == "Book A"
        assert r0["outcome"] == "success"
        assert r1["book_title"] == "Book B"
        assert r1["outcome"] == "failed"

    def test_record_contains_required_fields(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        log_session(
            book_title="My Book",
            book_author="Author Name",
            language="pt-BR",
            engine="edge",
            voice="pt-BR-ThalitaMultilingualNeural",
            chapters_total=10,
            chapters_converted=9,
            chapters_failed=1,
            duration_seconds=120.5,
            outcome="partial",
            job_id="abc-123",
            output_dir="/output/My_Book",
        )
        record = json.loads(_LOG_FILE.read_text())
        assert record["book_title"] == "My Book"
        assert record["book_author"] == "Author Name"
        assert record["language"] == "pt-BR"
        assert record["engine"] == "edge"
        assert record["voice"] == "pt-BR-ThalitaMultilingualNeural"
        assert record["chapters_total"] == 10
        assert record["chapters_converted"] == 9
        assert record["chapters_failed"] == 1
        assert record["duration_seconds"] == 120.5
        assert record["outcome"] == "partial"
        assert record["job_id"] == "abc-123"
        assert record["output_dir"] == "/output/My_Book"
        assert "timestamp" in record
        assert "mode" in record

    def test_job_id_and_output_dir_absent_when_empty(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        log_session(book_title="CLI Book", job_id="", output_dir="")
        record = json.loads(_LOG_FILE.read_text())
        assert "job_id" not in record
        assert "output_dir" not in record

    def test_extra_fields_merged_into_record(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        log_session(book_title="B", extra={"error": "timeout", "retry_count": 3})
        record = json.loads(_LOG_FILE.read_text())
        assert record["error"] == "timeout"
        assert record["retry_count"] == 3

    def test_started_at_used_as_timestamp_when_provided(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        ts = "2026-03-16T10:00:00+00:00"
        log_session(book_title="B", started_at=ts)
        record = json.loads(_LOG_FILE.read_text())
        assert record["timestamp"] == ts

    def test_duration_rounded_to_one_decimal(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        log_session(book_title="B", duration_seconds=123.456789)
        record = json.loads(_LOG_FILE.read_text())
        assert record["duration_seconds"] == 123.5


# ---------------------------------------------------------------------------
# read_sessions
# ---------------------------------------------------------------------------


class TestReadSessions:
    def test_returns_empty_list_when_file_missing(self, tmp_logs_dir):
        from python_app.src.session_logger import read_sessions

        assert read_sessions() == []

    def test_returns_all_records(self, tmp_logs_dir):
        from python_app.src.session_logger import log_session, read_sessions

        for i in range(5):
            log_session(book_title=f"Book {i}")
        records = read_sessions()
        assert len(records) == 5

    def test_last_n_returns_tail(self, tmp_logs_dir):
        from python_app.src.session_logger import log_session, read_sessions

        for i in range(10):
            log_session(book_title=f"Book {i}")
        records = read_sessions(last_n=3)
        assert len(records) == 3
        assert records[-1]["book_title"] == "Book 9"

    def test_skips_corrupt_lines(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session, read_sessions

        log_session(book_title="Good Book")
        with open(_LOG_FILE, "a") as fh:
            fh.write("{bad json}\n")
        log_session(book_title="Another Good Book")
        records = read_sessions()
        assert len(records) == 2


# ---------------------------------------------------------------------------
# chapter_details in session record
# ---------------------------------------------------------------------------


class TestChapterDetails:
    def test_chapter_details_stored_in_record(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        details = [
            {
                "index": 1,
                "name": "Chapter 1",
                "engine": "edge",
                "elapsedSeconds": 42.0,
                "status": "completed",
            },
            {
                "index": 2,
                "name": "Chapter 2",
                "engine": "piper",
                "elapsedSeconds": 65.3,
                "status": "completed",
                "retryCount": 1,
                "engineSequence": ["edge", "piper"],
            },
        ]
        log_session(book_title="Book", chapter_details=details)
        record = json.loads(_LOG_FILE.read_text())
        assert record["chapter_details"] == details

    def test_chapter_details_absent_when_none(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        log_session(book_title="Book", chapter_details=None)
        record = json.loads(_LOG_FILE.read_text())
        assert "chapter_details" not in record

    def test_chapter_details_absent_when_empty_list(self, tmp_logs_dir):
        from python_app.src.session_logger import _LOG_FILE, log_session

        log_session(book_title="Book", chapter_details=[])
        record = json.loads(_LOG_FILE.read_text())
        assert "chapter_details" not in record


# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------


class TestDetectMode:
    def test_cli_when_no_env(self, monkeypatch):
        from python_app.src import session_logger as sl

        monkeypatch.delenv("SPACE_ID", raising=False)
        monkeypatch.delenv("SERVER_MODE", raising=False)
        assert sl._detect_mode() == "cli"

    def test_hf_when_space_id_set(self, monkeypatch):
        from python_app.src import session_logger as sl

        monkeypatch.setenv("SPACE_ID", "owner/space-name")
        assert sl._detect_mode() == "hf"

    def test_web_when_server_mode_set(self, monkeypatch):
        from python_app.src import session_logger as sl

        monkeypatch.delenv("SPACE_ID", raising=False)
        monkeypatch.setenv("SERVER_MODE", "1")
        assert sl._detect_mode() == "web"


# ---------------------------------------------------------------------------
# GET /api/sessions endpoint
# ---------------------------------------------------------------------------


class TestSessionsEndpoint:
    def _make_client(self):
        import unittest

        try:
            from fastapi.testclient import TestClient
        except ModuleNotFoundError:
            raise unittest.SkipTest("fastapi not installed")
        from python_app import server

        return TestClient(server.app), server

    def test_returns_empty_when_no_log(self, monkeypatch, tmp_path):
        client, server = self._make_client()
        fake_log = tmp_path / "conversions.jsonl"
        monkeypatch.setattr("src.session_logger._LOG_FILE", fake_log)
        resp = client.get("/api/sessions")
        assert resp.status_code == 200
        data = resp.json()
        assert data["sessions"] == []
        assert data["count"] == 0

    def test_returns_all_records(self, monkeypatch, tmp_path):
        client, server = self._make_client()
        fake_log = tmp_path / "conversions.jsonl"
        records = [
            {
                "book_title": "Book A",
                "outcome": "success",
                "engine": "edge",
                "mode": "cli",
                "duration_seconds": 60.0,
                "chapters_converted": 5,
            },
            {
                "book_title": "Book B",
                "outcome": "failed",
                "engine": "kokoro",
                "mode": "web",
                "duration_seconds": 30.0,
                "chapters_converted": 2,
            },
        ]
        fake_log.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
        monkeypatch.setattr("src.session_logger._LOG_FILE", fake_log)

        resp = client.get("/api/sessions")
        assert resp.status_code == 200
        data = resp.json()
        assert data["count"] == 2
        assert data["sessions"][0]["book_title"] == "Book A"

    def test_last_param_limits_results(self, monkeypatch, tmp_path):
        client, server = self._make_client()
        fake_log = tmp_path / "conversions.jsonl"
        lines = [json.dumps({"book_title": f"Book {i}", "outcome": "success"}) for i in range(10)]
        fake_log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        monkeypatch.setattr("src.session_logger._LOG_FILE", fake_log)

        resp = client.get("/api/sessions?last=3")
        data = resp.json()
        assert data["count"] == 3
        assert data["sessions"][0]["book_title"] == "Book 7"

    def test_stats_aggregated(self, monkeypatch, tmp_path):
        client, server = self._make_client()
        fake_log = tmp_path / "conversions.jsonl"
        records = [
            {
                "outcome": "success",
                "engine": "edge",
                "mode": "cli",
                "duration_seconds": 100.0,
                "chapters_converted": 10,
            },
            {
                "outcome": "success",
                "engine": "edge",
                "mode": "web",
                "duration_seconds": 50.0,
                "chapters_converted": 5,
            },
            {
                "outcome": "failed",
                "engine": "piper",
                "mode": "hf",
                "duration_seconds": 20.0,
                "chapters_converted": 1,
            },
        ]
        fake_log.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
        monkeypatch.setattr("src.session_logger._LOG_FILE", fake_log)

        resp = client.get("/api/sessions")
        stats = resp.json()["stats"]
        assert stats["outcomes"]["success"] == 2
        assert stats["outcomes"]["failed"] == 1
        assert stats["engines"]["edge"] == 2
        assert stats["engines"]["piper"] == 1
        assert stats["modes"]["cli"] == 1
        assert stats["total_duration_seconds"] == 170.0
        assert stats["total_chapters_converted"] == 16
