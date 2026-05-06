# -*- coding: utf-8 -*-
"""Async wrappers for ffprobe/ffmpeg/silencedetect subprocess calls.

The audio post-processing pipeline (ID3 tagging, duration probe,
silence detection, optional silence injection) historically ran 3
subprocess.run() calls back-to-back per chapter, blocking the async
event loop while the chapter loop already had idle CPU slots elsewhere.

This module provides ``run_async`` (a thin asyncio.to_thread shim around
subprocess.run) plus convenience helpers for the calls that show up in
the hot path. Callers can ``await asyncio.gather(probe(), silencedetect())``
to overlap independent ffmpeg invocations on the same file.
"""

from __future__ import annotations

import asyncio
import subprocess
from typing import Optional, Sequence


async def run_async(
    cmd: Sequence[str],
    *,
    capture_output: bool = True,
    text: bool = True,
    check: bool = False,
    timeout: Optional[float] = None,
) -> subprocess.CompletedProcess:
    """Run a subprocess in a worker thread, returning the CompletedProcess.

    Mirrors ``subprocess.run`` semantics exactly — same fields on the
    returned object, same exceptions on timeout. The only difference is
    that the caller's coroutine yields instead of blocking the event
    loop while the subprocess executes.
    """
    return await asyncio.to_thread(
        subprocess.run,
        list(cmd),
        capture_output=capture_output,
        text=text,
        check=check,
        timeout=timeout,
    )


async def ffprobe_duration(audio_path: str, *, timeout: float = 10.0) -> Optional[float]:
    """Return the duration in seconds for an audio file, or ``None`` on failure."""
    try:
        result = await run_async(
            (
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(audio_path),
            ),
            timeout=timeout,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    value = (result.stdout or "").strip()
    if not value:
        return None
    try:
        duration = float(value)
    except ValueError:
        return None
    return duration if duration > 0 else None


__all__ = ["run_async", "ffprobe_duration"]
