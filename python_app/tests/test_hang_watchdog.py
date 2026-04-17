# -*- coding: utf-8 -*-
"""Regression tests for the unkillable-chapter hang.

The bug (observed 2026-04-17, PID 72659): the CLI conversion stalled on
chapter 6 for 20+ minutes after the last segment_success event.  The
``asyncio.wait_for`` around the synthesis task had cancelled the coroutine,
but the inner ``await stream.aclose()`` never returned — so ``wait_for``'s
post-cancel ``await task`` hung forever, freezing the whole job.

These tests lock in the fix:

* ``_safe_cancel_task`` must *not* block indefinitely on a non-cooperative
  task; it detaches after the grace deadline.
* ``_await_task_with_deadline`` must always return (``TimeoutError`` or the
  result) and never hang, even when the inner task ignores cancellation.
* ``_watch_segment_idle`` (CLI) and ``_segment_idle_watchdog`` (server)
  must cancel when no ``hits`` progress is observed for ``idle_seconds``.
* The two idle watchdogs must agree — they guard the same hang scenario
  on the dual-path architecture.
"""

from __future__ import annotations

import asyncio

import pytest
from src._health_watchdog_mixin import (
    _await_task_with_deadline,
    _safe_cancel_task,
)


class _Progress:
    """Minimal stand-in for ProgressTracker used by _watch_segment_idle."""

    def __init__(self) -> None:
        self._t = 0.0

    def mark_activity(self) -> None:
        self._t = 0.0


class _Dummy:
    """Provides the _watch_segment_idle mixin bound method for tests."""

    def __init__(self) -> None:
        from src._health_watchdog_mixin import _HealthWatchdogMixin

        self.progress = _Progress()
        self._watch_segment_idle = _HealthWatchdogMixin._watch_segment_idle.__get__(
            self, _HealthWatchdogMixin
        )


# ── _safe_cancel_task ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_safe_cancel_returns_quickly_on_cooperative_task():
    async def cooperative():
        try:
            await asyncio.sleep(60)
        except asyncio.CancelledError:
            raise

    task = asyncio.create_task(cooperative())
    await asyncio.sleep(0)  # let task start
    result = await _safe_cancel_task(task, grace=2.0)
    assert result is True
    assert task.done()


@pytest.mark.asyncio
async def test_safe_cancel_bails_on_non_cooperative_task():
    """The exact failure mode from the hang: a task that swallows cancel."""

    async def stubborn():
        while True:
            try:
                await asyncio.sleep(0.05)
            except asyncio.CancelledError:
                # Swallow cancellation — simulates non-cooperative HTTP stream
                continue

    task = asyncio.create_task(stubborn())
    await asyncio.sleep(0)
    # Must return False within bounded grace instead of hanging forever.
    result = await asyncio.wait_for(_safe_cancel_task(task, grace=0.3), timeout=2.0)
    assert result is False
    assert not task.done()
    # Clean up so the test doesn't leak a runaway task.
    with __import__("contextlib").suppress(Exception):
        task._coro.close()  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_safe_cancel_accepts_none_and_done():
    assert await _safe_cancel_task(None) is True

    async def trivial() -> int:
        return 42

    done_task = asyncio.create_task(trivial())
    await done_task
    assert await _safe_cancel_task(done_task) is True


# ── _await_task_with_deadline ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_await_with_deadline_returns_result_when_completed():
    async def fast() -> str:
        await asyncio.sleep(0.01)
        return "ok"

    task = asyncio.create_task(fast())
    result = await _await_task_with_deadline(task, timeout=1.0)
    assert result == "ok"


@pytest.mark.asyncio
async def test_await_with_deadline_raises_timeout_when_slow():
    async def slow():
        await asyncio.sleep(5)

    task = asyncio.create_task(slow())
    with pytest.raises(asyncio.TimeoutError):
        await _await_task_with_deadline(task, timeout=0.1, grace=0.5)


@pytest.mark.asyncio
async def test_await_with_deadline_detaches_non_cooperative_task():
    """Key invariant: even if the task ignores cancel, we must return.

    Measures wall-clock: the helper must return within roughly
    ``timeout + grace`` seconds, not hang for the full outer deadline.
    """
    import time as _time

    async def stubborn():
        while True:
            try:
                await asyncio.sleep(0.02)
            except asyncio.CancelledError:
                continue  # swallow forever

    task = asyncio.create_task(stubborn())
    start = _time.monotonic()
    with pytest.raises(asyncio.TimeoutError):
        await _await_task_with_deadline(task, timeout=0.1, grace=0.3)
    elapsed = _time.monotonic() - start
    # timeout (0.1) + grace (0.3) = 0.4s; allow a generous ceiling but
    # prove we did NOT wait on the non-cooperative task for minutes.
    assert elapsed < 2.0, f"helper blocked on uncancellable task for {elapsed:.2f}s"
    # Force-close the detached coroutine so it doesn't jam the loop teardown.
    with __import__("contextlib").suppress(Exception):
        task._coro.close()  # type: ignore[attr-defined]


# ── _watch_segment_idle (CLI) ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_segment_idle_watchdog_cancels_when_no_hits():
    dummy = _Dummy()
    state = {"hits": 0}

    async def stuck():
        try:
            await asyncio.sleep(30)
        except asyncio.CancelledError:
            raise

    task = asyncio.create_task(stuck())
    stall = asyncio.Event()
    await asyncio.gather(
        dummy._watch_segment_idle(
            chapter_index=7,
            task=task,
            progress_state=state,
            idle_seconds=0.3,
            check_interval=0.1,
            stall_event=stall,
        ),
        _wait_cancelled(task),
    )
    assert stall.is_set()
    assert task.done()


@pytest.mark.asyncio
async def test_segment_idle_watchdog_stays_alive_while_progressing():
    dummy = _Dummy()
    state = {"hits": 0}

    async def progressing():
        # Advance the counter five times, then finish normally.
        for _ in range(5):
            state["hits"] += 1
            await asyncio.sleep(0.1)
        return "done"

    task = asyncio.create_task(progressing())
    watchdog = asyncio.create_task(
        dummy._watch_segment_idle(
            chapter_index=9,
            task=task,
            progress_state=state,
            idle_seconds=0.6,
            check_interval=0.1,
        )
    )
    result = await task
    await watchdog
    assert result == "done"


# ── server mirror: _segment_idle_watchdog ─────────────────────────────────


@pytest.mark.asyncio
async def test_server_segment_idle_watchdog_cancels_stuck_task():
    import python_app.server as srv

    state = {"hits": 0}

    async def stuck():
        try:
            await asyncio.sleep(30)
        except asyncio.CancelledError:
            raise

    task = asyncio.create_task(stuck())
    await srv._segment_idle_watchdog(
        task, state, idle_seconds=0.3, chapter_index=1, check_interval=0.1
    )
    await _wait_cancelled(task)
    assert task.done()


@pytest.mark.asyncio
async def test_server_segment_idle_watchdog_tracks_hits():
    import python_app.server as srv

    state = {"hits": 0}

    async def progressing():
        for _ in range(5):
            state["hits"] += 1
            await asyncio.sleep(0.08)
        return "ok"

    task = asyncio.create_task(progressing())
    watchdog = asyncio.create_task(
        srv._segment_idle_watchdog(
            task, state, idle_seconds=0.6, chapter_index=1, check_interval=0.08
        )
    )
    assert await task == "ok"
    await watchdog


# ── helpers ───────────────────────────────────────────────────────────────


async def _wait_cancelled(task: asyncio.Task) -> None:
    try:
        await task
    except (asyncio.CancelledError, Exception):
        pass
