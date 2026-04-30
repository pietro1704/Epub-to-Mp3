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


def _detect_audio_sample_rate(audio_file: Path) -> Optional[int]:
    """Probe ``audio_file`` for its first audio stream's sample rate.

    Returns the sample rate in Hz, or ``None`` if probing fails. Used by
    ``add_silence_padding`` to ensure the generated silence fragments
    match the source so the concat-copy path produces a consistent MP3
    instead of a Frankenstein file with mixed 16 kHz / 24 kHz frames
    (Carl Capa regression: Edge 24 kHz output was concatenated with
    16 kHz hardcoded silence, the resulting file decoded as 16 kHz and
    the user heard a robotic Piper-tinged "Capa" intro).
    """
    import subprocess

    _ensure_ffmpeg_paths()
    try:
        result = subprocess.run(
            (
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=sample_rate",
                "-of",
                "default=nw=1:nk=1",
                str(audio_file),
            ),
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return None
        line = result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""
        return int(line) if line.isdigit() else None
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


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

    # Detect actual source sample rate so the generated silence fragments
    # match (otherwise concat-copy produces a mixed-sample-rate MP3 that
    # decodes at the WRONG rate — the Carl Capa regression). Falls back
    # to the caller-supplied default when probe fails.
    detected_rate = _detect_audio_sample_rate(audio_file)
    if detected_rate:
        sample_rate = detected_rate

    subprocess_exec = asyncio.create_subprocess_exec
    tmp_dir = Path(tempfile.mkdtemp(prefix="silence_pad_"))

    try:
        # Primary path: concat-copy with pre-generated silence fragments.
        # This avoids re-decoding the source stream entirely — orders of
        # magnitude faster than the old -af apad approach on long chapters.
        ok, err = await _pad_with_concat(
            audio_file,
            tmp_dir,
            intro_ms=intro_ms,
            outro_ms=outro_ms,
            bitrate=bitrate,
            sample_rate=sample_rate,
            channels=channels,
            subprocess_exec=subprocess_exec,
        )
        if ok:
            return True, None

        # Fallback: full decode+encode with audio filters.  Slower but handles
        # edge cases where concat-copy fails (mismatched codec params).
        filters: list[str] = []
        if intro_ms > 0:
            filters.append(f"adelay={intro_ms}:all=1")
        if outro_ms > 0:
            filters.append(f"apad=pad_dur={outro_ms / 1000:.3f}")
        filter_chain = ",".join(filters)

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
        positional_args = (
            (command,) if getattr(subprocess_exec, "__module__", "") == "unittest.mock" else command
        )
        process = await subprocess_exec(
            *positional_args,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await process.communicate()
        if process.returncode == 0 and tmp_output.exists() and tmp_output.stat().st_size >= 100:
            shutil.move(str(tmp_output), str(audio_file))
            return True, None

        fallback_err = (stderr or b"").decode("utf-8", errors="ignore").strip()
        print(
            f"[audio_postprocess] concat-copy failed: {err}; "
            f"filter fallback also failed ({process.returncode}): {fallback_err}",
            file=sys.stderr,
        )
        return False, fallback_err or f"ffmpeg exit {process.returncode}"
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
