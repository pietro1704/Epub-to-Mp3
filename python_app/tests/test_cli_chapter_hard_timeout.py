# -*- coding: utf-8 -*-
"""Regression test for CLI chapter hard-timeout fallback.

Observed 2026-04-21 (PID 89272): conversion stalled at chapter 6.6 for ~2h.
The `asyncio.wait(FIRST_COMPLETED)` in `_convert_chapters_parallel` never
returned because the in-flight task was hung inside post-TTS work that
doesn't emit heartbeats. The existing watchdog reduced concurrency to 1
and then gave up ("current cannot go lower").

Fix: wrap every chapter task in `asyncio.wait_for(..., timeout=
CLI_CHAPTER_HARD_TIMEOUT_SECONDS)` (default 900s). On timeout we return
a `ConversionResult` failure for that chapter instead of hanging forever.
"""

from __future__ import annotations

import asyncio

import pytest


@pytest.mark.asyncio
async def test_wait_for_deadline_returns_failure_instead_of_hanging():
    """Simulates the wrapper: a coroutine that never completes must be
    cancelled and yield a ConversionResult failure within the deadline."""
    from src.converter import ConversionResult

    async def _hung_chapter():
        await asyncio.Event().wait()  # never completes
        return ConversionResult(
            success=True,
            total_chapters=1,
            converted_chapters=1,
            output_files=[],
            errors=[],
        )

    hard_timeout = 0.3

    async def _with_deadline(coro):
        try:
            return await asyncio.wait_for(coro, timeout=hard_timeout)
        except asyncio.TimeoutError:
            return ConversionResult(
                success=False,
                total_chapters=1,
                converted_chapters=0,
                output_files=[],
                errors=[f"hard timeout {hard_timeout}s"],
            )

    started = asyncio.get_event_loop().time()
    result = await _with_deadline(_hung_chapter())
    elapsed = asyncio.get_event_loop().time() - started

    assert isinstance(result, ConversionResult)
    assert result.success is False
    assert result.converted_chapters == 0
    assert any("hard timeout" in e for e in result.errors)
    # Must not hang — allow generous slack for CI.
    assert elapsed < hard_timeout + 2.0


@pytest.mark.asyncio
async def test_wait_for_deadline_passes_through_fast_chapter():
    """A chapter that finishes before the deadline returns its real result."""
    from src.converter import ConversionResult

    async def _fast_chapter():
        await asyncio.sleep(0.01)
        return ConversionResult(
            success=True,
            total_chapters=1,
            converted_chapters=1,
            output_files=[],
            errors=[],
        )

    async def _with_deadline(coro):
        try:
            return await asyncio.wait_for(coro, timeout=5.0)
        except asyncio.TimeoutError:
            return ConversionResult(
                success=False,
                total_chapters=1,
                converted_chapters=0,
                output_files=[],
                errors=["hard timeout"],
            )

    result = await _with_deadline(_fast_chapter())
    assert result.success is True
    assert result.converted_chapters == 1
