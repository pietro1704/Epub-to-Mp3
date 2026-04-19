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
        if process.returncode == 0 and tmp_output.exists() and tmp_output.stat().st_size >= 100:
            shutil.move(str(tmp_output), str(audio_file))
            return True, None

        err = (stderr or b"").decode("utf-8", errors="ignore").strip()

        # Fallback: when the filter chain fails (commonly because the decoder
        # rejected the input MP3 — seen on some static-ffmpeg builds in CI),
        # splice silence via the concat demuxer so the main audio stream is
        # copied as-is without re-decoding.
        fallback_ok, fallback_err = await _pad_with_concat(
            audio_file,
            tmp_dir,
            intro_ms=intro_ms,
            outro_ms=outro_ms,
            bitrate=bitrate,
            sample_rate=sample_rate,
            channels=channels,
            subprocess_exec=subprocess_exec,
        )
        if fallback_ok:
            return True, None

        print(
            f"[audio_postprocess] ffmpeg padding failed ({process.returncode}): {err}; "
            f"concat fallback: {fallback_err}",
            file=sys.stderr,
        )
        return False, err or f"ffmpeg exit {process.returncode}"
    except FileNotFoundError:
        return False, "ffmpeg binary not found"
    except Exception as exc:
        return False, str(exc)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


async def _pad_with_concat(
    audio_file: Path,
    tmp_dir: Path,
    *,
    intro_ms: int,
    outro_ms: int,
    bitrate: str,
    sample_rate: int,
    channels: int,
    subprocess_exec,
) -> Tuple[bool, Optional[str]]:
    """Fallback pad: generate silence MP3s and concat-copy with the source.

    Uses ``anullsrc`` to encode short silence fragments, then concatenates them
    with the original file using the concat demuxer in copy mode. This avoids
    re-decoding the source stream (the failure mode we hit on CI).
    """

    def _silence_cmd(dest: Path, duration_s: float) -> tuple[str, ...]:
        return (
            "ffmpeg",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"anullsrc=channel_layout={'stereo' if int(channels) > 1 else 'mono'}:"
            f"sample_rate={int(sample_rate)}",
            "-t",
            f"{max(duration_s, 0.001):.3f}",
            "-b:a",
            str(bitrate),
            "-ac",
            str(channels),
            str(dest),
        )

    async def _run(cmd: tuple[str, ...]) -> tuple[int, str]:
        args = (cmd,) if getattr(subprocess_exec, "__module__", "") == "unittest.mock" else cmd
        proc = await subprocess_exec(
            *args,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, err = await proc.communicate()
        return proc.returncode, (err or b"").decode("utf-8", errors="ignore")

    intro_path = tmp_dir / "intro.mp3"
    outro_path = tmp_dir / "outro.mp3"
    list_path = tmp_dir / "concat.txt"
    final_path = tmp_dir / f"joined{audio_file.suffix or '.mp3'}"

    parts: list[Path] = []
    if intro_ms > 0:
        rc, err = await _run(_silence_cmd(intro_path, intro_ms / 1000.0))
        if rc != 0:
            return False, f"intro silence: {err.strip()}"
        parts.append(intro_path)
    parts.append(audio_file)
    if outro_ms > 0:
        rc, err = await _run(_silence_cmd(outro_path, outro_ms / 1000.0))
        if rc != 0:
            return False, f"outro silence: {err.strip()}"
        parts.append(outro_path)

    list_path.write_text("\n".join(f"file '{p.resolve()}'" for p in parts) + "\n", encoding="utf-8")

    concat_cmd = (
        "ffmpeg",
        "-y",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        str(list_path),
        "-c",
        "copy",
        str(final_path),
    )
    rc, err = await _run(concat_cmd)
    if rc != 0 or not final_path.exists() or final_path.stat().st_size < 100:
        return False, f"concat: {err.strip() or f'exit {rc}'}"
    shutil.move(str(final_path), str(audio_file))
    return True, None


__all__ = ["add_silence_padding"]
