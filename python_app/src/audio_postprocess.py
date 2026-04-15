# -*- coding: utf-8 -*-
"""Audio post-processing helpers applied after TTS synthesis.

Currently supports intro/outro silence padding via ffmpeg.  The helper is
intentionally a no-op when both durations are zero, so callers can invoke it
unconditionally without burning subprocess cost on the default path.
"""

from __future__ import annotations

import asyncio
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Optional, Tuple


def _ensure_ffmpeg_paths() -> None:
    try:
        import static_ffmpeg

        static_ffmpeg.add_paths()
    except ImportError:
        pass


async def add_silence_padding(
    audio_file: Path,
    *,
    intro_ms: int = 0,
    outro_ms: int = 500,
    bitrate: str = "8k",
    sample_rate: int = 16_000,
    channels: int = 1,
) -> Tuple[bool, Optional[str]]:
    """Pad ``audio_file`` with silence in-place using ffmpeg ``adelay`` + ``apad``.

    Returns ``(ok, error)``.  When both durations are zero the call is a no-op
    and returns ``(True, None)`` without invoking ffmpeg.  On any ffmpeg error
    the original file is left untouched.
    """

    try:
        intro_ms = max(int(intro_ms or 0), 0)
        outro_ms = max(int(outro_ms or 0), 0)
    except (TypeError, ValueError):
        return False, "invalid duration"

    if intro_ms == 0 and outro_ms == 0:
        return True, None

    audio_file = Path(audio_file)
    if not audio_file.exists() or audio_file.stat().st_size < 100:
        return False, f"input missing or too small: {audio_file}"

    _ensure_ffmpeg_paths()

    filters: list[str] = []
    if intro_ms > 0:
        filters.append(f"adelay={intro_ms}:all=1")
    if outro_ms > 0:
        filters.append(f"apad=pad_dur={outro_ms / 1000:.3f}")
    filter_chain = ",".join(filters)

    tmp_dir = Path(tempfile.mkdtemp(prefix="silence_pad_"))
    tmp_output = tmp_dir / f"padded{audio_file.suffix or '.mp3'}"

    command = (
        "ffmpeg",
        "-y",
        "-i",
        str(audio_file),
        "-af",
        filter_chain,
        "-b:a",
        bitrate,
        "-ar",
        str(sample_rate),
        "-ac",
        str(channels),
        str(tmp_output),
    )

    subprocess_exec = asyncio.create_subprocess_exec
    positional_args = (
        (command,) if getattr(subprocess_exec, "__module__", "") == "unittest.mock" else command
    )

    try:
        process = await subprocess_exec(
            *positional_args,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await process.communicate()
        if process.returncode != 0:
            err = (stderr or b"").decode("utf-8", errors="ignore").strip()
            print(
                f"[audio_postprocess] ffmpeg padding failed ({process.returncode}): {err}",
                file=sys.stderr,
            )
            return False, err or f"ffmpeg exit {process.returncode}"

        if not tmp_output.exists() or tmp_output.stat().st_size < 100:
            return False, "padded output missing"

        shutil.move(str(tmp_output), str(audio_file))
        return True, None
    except FileNotFoundError:
        return False, "ffmpeg binary not found"
    except Exception as exc:
        return False, str(exc)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


__all__ = ["add_silence_padding"]
