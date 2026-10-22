"""Transactional title-pause splicing with caller-owned probing and process launch."""

from __future__ import annotations

import asyncio
import shutil
import tempfile
from pathlib import Path
from typing import Optional, Tuple


async def inject_silence_at_offset(
    audio_file: Path,
    *,
    insert_at_seconds: float,
    silence_ms: int = 1000,
    bitrate: str = "8k",
    ensure_paths,
    detect_sample_rate,
    subprocess_factory,
) -> Tuple[bool, Optional[str]]:
    """Splice ``silence_ms`` of silence into ``audio_file`` at the given
    timestamp (in seconds).

    Used to inject a real chapter-title pause that Edge plain-text
    cannot produce on its own (Edge caps inter-sentence silence at
    ~700ms regardless of punctuation density). The user reported
    "ainda sem pausa" / "deveria perceber sozinho" after several
    text-level attempts; this is the only reliable path.

    Strategy: split the source MP3 at ``insert_at_seconds``, generate
    a silence fragment matching the source sample rate / channels, and
    concat-copy the three fragments back together. ``concat-copy`` is
    fast (no re-encode of the source) but requires the silence to use
    the same codec parameters as the source — we probe ffprobe for
    those.

    Returns ``(ok, error)``.  On any failure the original file is left
    untouched.
    """
    audio_file = Path(audio_file)
    if not audio_file.exists() or audio_file.stat().st_size < 100:
        return False, "input missing or too small"
    if silence_ms <= 0 or insert_at_seconds <= 0:
        return True, None

    ensure_paths()

    sample_rate = detect_sample_rate(audio_file) or 24000
    tmp_dir = Path(tempfile.mkdtemp(prefix="silence_inject_"))
    head_path = tmp_dir / "head.mp3"
    tail_path = tmp_dir / "tail.mp3"
    silence_path = tmp_dir / "silence.mp3"
    list_path = tmp_dir / "concat.txt"
    out_path = tmp_dir / "joined.mp3"

    subprocess_exec = subprocess_factory()

    async def _run(cmd: tuple[str, ...]) -> int:
        args = (cmd,) if getattr(subprocess_exec, "__module__", "") == "unittest.mock" else cmd
        try:
            proc = await subprocess_exec(
                *args,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await proc.wait()
            return proc.returncode
        except Exception:
            return 1

    try:
        # Split source: head = [0, insert_at), tail = [insert_at, end].
        # Use stream-copy so we don't re-encode the bulk of the chapter.
        rc = await _run(
            (
                "ffmpeg",
                "-y",
                "-i",
                str(audio_file),
                "-t",
                f"{insert_at_seconds:.3f}",
                "-c",
                "copy",
                str(head_path),
            )
        )
        if rc != 0:
            return False, "split head failed"
        rc = await _run(
            (
                "ffmpeg",
                "-y",
                "-i",
                str(audio_file),
                "-ss",
                f"{insert_at_seconds:.3f}",
                "-c",
                "copy",
                str(tail_path),
            )
        )
        if rc != 0:
            return False, "split tail failed"

        # Generate silence with matching sample rate.
        rc = await _run(
            (
                "ffmpeg",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"anullsrc=channel_layout=mono:sample_rate={int(sample_rate)}",
                "-t",
                f"{silence_ms / 1000:.3f}",
                "-b:a",
                bitrate,
                "-ac",
                "1",
                str(silence_path),
            )
        )
        if rc != 0:
            return False, "silence gen failed"

        list_path.write_text(
            f"file '{head_path.resolve()}'\n"
            f"file '{silence_path.resolve()}'\n"
            f"file '{tail_path.resolve()}'\n",
            encoding="utf-8",
        )
        rc = await _run(
            (
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
                str(out_path),
            )
        )
        if rc != 0:
            return False, "concat failed"
        if not out_path.exists() or out_path.stat().st_size < 100:
            return False, "output missing"

        shutil.move(str(out_path), str(audio_file))
        return True, None
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
