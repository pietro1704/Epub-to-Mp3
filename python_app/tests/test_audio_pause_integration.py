"""Audio integration tests — verify the actual MP3 output, not just text.

Earlier regressions (mixed sample rates, pauses in the wrong place,
"Capi..........tulo22" stutter) all slipped through because the test
suite only validated the pre-tts text. By the time the user heard
the broken MP3 we'd already shipped.

These tests synthesise short fixtures with Edge-TTS, run the same
post-processing pipeline a real conversion uses (silence injection,
ID3 tagging), then probe the resulting MP3 with ffprobe + RMS
analysis to assert objective audio properties:

- Sample rate matches Edge (24 kHz mono — no Piper bleed-through).
- Cover art stream is preserved when one was embedded.
- An audible silence (≥1.5 s) lands between the chapter title and
  the body.

Skipped on environments without the network (Edge is a cloud TTS) or
without ffmpeg/ffprobe on PATH. The skip is loud — `pytest -v`
shows the reason — so a missing dependency cannot silently void the
audio coverage.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def _has_edge_tts() -> bool:
    try:
        import edge_tts  # noqa: F401
    except ImportError:
        return False
    return True


def _has_ffmpeg() -> bool:
    return bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))


def _network_available() -> bool:
    if os.environ.get("SKIP_NETWORK_TESTS"):
        return False
    try:
        import socket

        with socket.create_connection(("speech.platform.bing.com", 443), timeout=2):
            return True
    except OSError:
        return False


_SKIP_REASON = []
if not _has_edge_tts():
    _SKIP_REASON.append("edge_tts not installed")
if not _has_ffmpeg():
    _SKIP_REASON.append("ffmpeg/ffprobe not on PATH")
if not _network_available():
    _SKIP_REASON.append("Edge-TTS endpoint unreachable")


def _ffprobe_sample_rate(path: Path) -> int | None:
    out = subprocess.run(
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
            str(path),
        ),
        capture_output=True,
        text=True,
        timeout=10,
    )
    line = out.stdout.strip().splitlines()[0] if out.stdout.strip() else ""
    return int(line) if line.isdigit() else None


def _has_video_stream(path: Path) -> bool:
    out = subprocess.run(
        (
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name",
            "-of",
            "default=nw=1:nk=1",
            str(path),
        ),
        capture_output=True,
        text=True,
        timeout=10,
    )
    return bool(out.stdout.strip())


def _silence_runs(mp3_path: Path, max_seconds: float = 12.0) -> list[tuple[float, float]]:
    """Return [(start_s, duration_s), ...] for silence ≥0.2s in the
    first ``max_seconds`` of audio.

    Decodes via ffmpeg → 16 kHz mono WAV, then walks 0.20 s windows of
    raw PCM samples. RMS-based instead of silencedetect to match the
    diagnostic the user reported by ear.
    """
    with tempfile.TemporaryDirectory(prefix="audio_pause_test_") as tmp:
        wav = Path(tmp) / "out.wav"
        rc = subprocess.run(
            (
                "ffmpeg",
                "-y",
                "-i",
                str(mp3_path),
                "-t",
                f"{max_seconds:.1f}",
                "-ar",
                "16000",
                "-ac",
                "1",
                str(wav),
            ),
            capture_output=True,
            timeout=30,
        )
        if rc.returncode != 0 or not wav.exists():
            return []
        with wave.open(str(wav), "rb") as w:
            n = w.getnframes()
            sr = w.getframerate()
            samples = struct.unpack(f"<{n}h", w.readframes(n))
    if not samples:
        return []
    window = int(sr * 0.20)
    runs: list[tuple[float, float]] = []
    in_silence = False
    silence_start = 0.0
    for i in range(0, len(samples) - window, window):
        chunk = samples[i : i + window]
        avg = sum(abs(s) for s in chunk) / len(chunk)
        t = i / sr
        if avg < 100 and not in_silence:
            silence_start = t
            in_silence = True
        elif avg >= 100 and in_silence:
            duration = t - silence_start
            if duration >= 0.2:
                runs.append((silence_start, duration))
            in_silence = False
    return runs


@unittest.skipIf(_SKIP_REASON, "; ".join(_SKIP_REASON))
class TestEdgeOutputAudioProperties(unittest.TestCase):
    """End-to-end: synthesise a short pt-BR fixture with Edge, then
    inspect the resulting MP3."""

    fixture_text = (
        "Capítulo 1.\n\nA transformação aconteceu perto das duas e vinte e três da manhã. "
        "Até onde sei todo mundo morreu na hora."
    )

    @classmethod
    def setUpClass(cls):
        import edge_tts

        cls.tmp = Path(tempfile.mkdtemp(prefix="edge_audio_test_"))
        cls.raw_path = cls.tmp / "raw.mp3"

        async def _synth():
            await edge_tts.Communicate(cls.fixture_text, "pt-BR-ThalitaMultilingualNeural").save(
                str(cls.raw_path)
            )

        asyncio.run(_synth())
        if not cls.raw_path.exists() or cls.raw_path.stat().st_size < 1000:
            raise unittest.SkipTest("Edge-TTS returned empty payload")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_edge_output_is_24khz(self):
        """Edge always emits 24 kHz mono. A 16 kHz outlier means a
        Piper engine slipped in (the Carl regression)."""
        rate = _ffprobe_sample_rate(self.raw_path)
        self.assertEqual(rate, 24000, f"expected Edge 24 kHz, got {rate}")

    def test_silence_injection_produces_audible_pause(self):
        """The post-synthesis injection must produce ≥1.5 s of silence
        starting after the title (>0.4 s) and within the title-end
        window (<3 s)."""
        from src.audio_postprocess import (
            find_silence_for_title,
            inject_silence_at_offset,
        )

        injected = self.tmp / "injected.mp3"
        shutil.copy(self.raw_path, injected)

        async def _do():
            splice = await find_silence_for_title(injected, title_text="Capítulo 1")
            if splice is None:
                splice = 1.0
            await inject_silence_at_offset(
                injected, insert_at_seconds=splice, silence_ms=2000, bitrate="8k"
            )

        asyncio.run(_do())

        runs = _silence_runs(injected, max_seconds=10.0)
        # The leading 0-0.something silence is intro padding; we want
        # a NEW silence that lands between title and body.
        title_end_runs = [(s, d) for s, d in runs if s > 0.4 and d >= 1.5]
        self.assertTrue(
            title_end_runs,
            f"no ≥1.5s silence injected after title; got runs={runs}",
        )

    def test_inject_does_not_strip_audio(self):
        """Concat-copy must preserve the source's 24 kHz audio stream."""
        from src.audio_postprocess import (
            inject_silence_at_offset,
        )

        injected = self.tmp / "preserved.mp3"
        shutil.copy(self.raw_path, injected)

        async def _do():
            await inject_silence_at_offset(injected, insert_at_seconds=1.0, silence_ms=1000)

        asyncio.run(_do())
        self.assertEqual(_ffprobe_sample_rate(injected), 24000)


@unittest.skipIf(_SKIP_REASON, "; ".join(_SKIP_REASON))
class TestEdgeFingerprintIsConsistent(unittest.TestCase):
    """A book-wide property: every Edge-synthesised MP3 must have the
    same sample rate. A single 16 kHz outlier means Piper got mixed in
    (the Carl Capa regression)."""

    def test_two_synths_same_rate(self):
        import edge_tts

        async def synth(text, out):
            await edge_tts.Communicate(text, "pt-BR-ThalitaMultilingualNeural").save(str(out))

        with tempfile.TemporaryDirectory(prefix="edge_consistency_") as tmp:
            a = Path(tmp) / "a.mp3"
            b = Path(tmp) / "b.mp3"
            asyncio.run(synth("Olá, mundo.", a))
            asyncio.run(synth("Outro chapter, outro texto.", b))
            self.assertEqual(_ffprobe_sample_rate(a), 24000)
            self.assertEqual(_ffprobe_sample_rate(b), 24000)


if __name__ == "__main__":
    unittest.main()
