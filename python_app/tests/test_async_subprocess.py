# -*- coding: utf-8 -*-
"""v0.3.28: async wrappers around subprocess.run for ffprobe/ffmpeg
calls in the audio post-processing pipeline."""

from __future__ import annotations

import asyncio
import subprocess
from unittest.mock import AsyncMock, patch

from src._async_subprocess import ffprobe_duration, run_async


def test_run_async_returns_completed_process():
    result = asyncio.run(run_async(["echo", "hello"]))
    assert isinstance(result, subprocess.CompletedProcess)
    assert "hello" in result.stdout


def test_ffprobe_duration_parses_numeric_stdout():
    fake = subprocess.CompletedProcess(args=[], returncode=0, stdout="123.456\n", stderr="")
    with patch("src._async_subprocess.run_async", new=AsyncMock(return_value=fake)):
        result = asyncio.run(ffprobe_duration("/tmp/fake.mp3"))
    assert result == 123.456


def test_ffprobe_duration_returns_none_on_nonzero_returncode():
    fake = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="error")
    with patch("src._async_subprocess.run_async", new=AsyncMock(return_value=fake)):
        result = asyncio.run(ffprobe_duration("/tmp/fake.mp3"))
    assert result is None


def test_ffprobe_duration_returns_none_on_unparseable():
    fake = subprocess.CompletedProcess(args=[], returncode=0, stdout="not a number", stderr="")
    with patch("src._async_subprocess.run_async", new=AsyncMock(return_value=fake)):
        result = asyncio.run(ffprobe_duration("/tmp/fake.mp3"))
    assert result is None


def test_ffprobe_duration_swallows_filenotfound():
    with patch(
        "src._async_subprocess.run_async",
        new=AsyncMock(side_effect=FileNotFoundError("ffprobe not on PATH")),
    ):
        result = asyncio.run(ffprobe_duration("/tmp/fake.mp3"))
    assert result is None
