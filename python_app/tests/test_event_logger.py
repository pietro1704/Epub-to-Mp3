"""Tests for log_event / perf / error / freeze structured event log."""

import json

import pytest


@pytest.fixture()
def tmp_events_file(tmp_path, monkeypatch):
    import python_app.src.session_logger as sl

    events_file = tmp_path / "events.jsonl"
    monkeypatch.setattr(sl, "_EVENTS_FILE", events_file)
    return events_file


class TestLogEvent:
    def test_creates_file_on_first_write(self, tmp_events_file):
        from python_app.src.session_logger import log_event

        assert not tmp_events_file.exists()
        log_event("perf", chapter_index=1)
        assert tmp_events_file.exists()

    def test_record_has_kind_timestamp_mode(self, tmp_events_file):
        from python_app.src.session_logger import log_event

        log_event("perf", value=42)
        record = json.loads(tmp_events_file.read_text())
        assert record["kind"] == "perf"
        assert record["value"] == 42
        assert "timestamp" in record
        assert "mode" in record

    def test_empty_kind_does_nothing(self, tmp_events_file):
        from python_app.src.session_logger import log_event

        log_event("", value=1)
        assert not tmp_events_file.exists()

    def test_skips_none_and_empty_string_fields(self, tmp_events_file):
        from python_app.src.session_logger import log_event

        log_event("perf", a=1, b=None, c="", d="x")
        record = json.loads(tmp_events_file.read_text())
        assert record["a"] == 1
        assert "b" not in record
        assert "c" not in record
        assert record["d"] == "x"

    def test_appends_multiple_lines(self, tmp_events_file):
        from python_app.src.session_logger import log_event

        for i in range(3):
            log_event("perf", i=i)
        lines = tmp_events_file.read_text().strip().splitlines()
        assert len(lines) == 3

    def test_never_raises_on_unserializable(self, tmp_events_file):
        from python_app.src.session_logger import log_event

        class Weird:
            def __repr__(self):
                return "weird"

        # default=str handles this; must not raise
        log_event("perf", obj=Weird())
        rec = json.loads(tmp_events_file.read_text())
        assert rec["obj"] == "weird"


class TestLogChapterPerf:
    def test_computes_chars_per_second(self, tmp_events_file):
        from python_app.src.session_logger import log_chapter_perf

        log_chapter_perf(
            book_title="B",
            chapter_index=4,
            chapter_name="Cap 4",
            engine="edge",
            elapsed_seconds=10.0,
            char_count=2500,
        )
        rec = json.loads(tmp_events_file.read_text())
        assert rec["kind"] == "chapter_perf"
        assert rec["chars_per_second"] == 250.0
        assert rec["engine"] == "edge"
        assert rec["chapter_index"] == 4

    def test_zero_elapsed_yields_zero_throughput(self, tmp_events_file):
        from python_app.src.session_logger import log_chapter_perf

        log_chapter_perf(elapsed_seconds=0.0, char_count=100)
        rec = json.loads(tmp_events_file.read_text())
        # chars_per_second is 0.0 → omitted
        assert "chars_per_second" not in rec or rec["chars_per_second"] == 0.0


class TestLogChapterError:
    def test_truncates_long_error_message(self, tmp_events_file):
        from python_app.src.session_logger import log_chapter_error

        big = "x" * 5000
        log_chapter_error(chapter_index=1, engine="edge", error=big)
        rec = json.loads(tmp_events_file.read_text())
        assert rec["kind"] == "chapter_error"
        assert len(rec["error"]) == 500


class TestLogFreeze:
    def test_records_source_and_threshold(self, tmp_events_file):
        from python_app.src.session_logger import log_freeze

        log_freeze(
            source="chapter_stall",
            chapter_index=7,
            stalled_seconds=92.4,
            threshold_seconds=90.0,
            action="cancel_and_restart_chapter",
        )
        rec = json.loads(tmp_events_file.read_text())
        assert rec["kind"] == "freeze"
        assert rec["source"] == "chapter_stall"
        assert rec["stalled_seconds"] == 92.4
        assert rec["threshold_seconds"] == 90.0
        assert rec["action"] == "cancel_and_restart_chapter"


class TestReadEvents:
    def test_returns_empty_when_missing(self, tmp_events_file):
        from python_app.src.session_logger import read_events

        assert read_events() == []

    def test_filter_by_kind(self, tmp_events_file):
        from python_app.src.session_logger import (
            log_chapter_error,
            log_chapter_perf,
            log_freeze,
            read_events,
        )

        log_chapter_perf(chapter_index=1, engine="edge", elapsed_seconds=1.0, char_count=100)
        log_chapter_error(chapter_index=2, engine="edge", error="boom")
        log_freeze(source="health", stalled_seconds=120.0, threshold_seconds=100.0)

        assert len(read_events()) == 3
        assert len(read_events(kind="chapter_perf")) == 1
        assert len(read_events(kind="freeze")) == 1
        assert read_events(kind="freeze")[0]["source"] == "health"

    def test_last_n(self, tmp_events_file):
        from python_app.src.session_logger import log_event, read_events

        for i in range(10):
            log_event("perf", i=i)
        recs = read_events(last_n=3)
        assert len(recs) == 3
        assert recs[-1]["i"] == 9

    def test_skips_corrupt_lines(self, tmp_events_file):
        from python_app.src.session_logger import log_event, read_events

        log_event("perf", i=1)
        with open(tmp_events_file, "a") as fh:
            fh.write("{not json}\n")
        log_event("perf", i=2)
        recs = read_events()
        assert len(recs) == 2


class TestClearEvents:
    def test_clear_removes_file_and_returns_count(self, tmp_events_file):
        from python_app.src.session_logger import clear_events, log_event

        for i in range(3):
            log_event("perf", i=i)
        assert tmp_events_file.exists()
        assert clear_events() == 3
        assert not tmp_events_file.exists()

    def test_clear_when_missing_returns_zero(self, tmp_events_file):
        from python_app.src.session_logger import clear_events

        assert clear_events() == 0


class TestWatchdogIntegration:
    """Verify the three watchdog sites in _health_watchdog_mixin call log_freeze."""

    def test_segment_idle_logs_freeze(self, tmp_events_file, monkeypatch):
        import asyncio
        import time

        from python_app.src._health_watchdog_mixin import _HealthWatchdogMixin

        class Dummy(_HealthWatchdogMixin):
            pass

        async def run():
            # task that never completes
            inner = asyncio.create_task(asyncio.sleep(5))
            progress = {"hits": 0}
            await Dummy()._watch_segment_idle(
                chapter_index=3,
                task=inner,
                progress_state=progress,
                idle_seconds=0.05,
                check_interval=2.0,
            )
            inner.cancel()

        # Force the loop to run quickly: stub asyncio.sleep inside the watchdog
        # by patching time.time so threshold trips on the first iteration.
        original_sleep = asyncio.sleep

        async def fast_sleep(_secs):
            await original_sleep(0)

        monkeypatch.setattr("python_app.src._health_watchdog_mixin.asyncio.sleep", fast_sleep)

        # Push "now" forward so idle elapsed exceeds 0.05s
        real_time = time.time
        offset = {"v": 0.0}

        def fake_time():
            return real_time() + offset["v"]

        monkeypatch.setattr("python_app.src._health_watchdog_mixin.time.time", fake_time)

        async def driver():
            t = asyncio.create_task(run())
            await original_sleep(0)
            offset["v"] = 10.0  # advance time
            await t

        asyncio.run(driver())

        from python_app.src.session_logger import read_events

        freezes = read_events(kind="freeze")
        assert any(f["source"] == "segment_idle" for f in freezes)
