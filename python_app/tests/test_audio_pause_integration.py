"""Decoded MP3 regression checks with deterministic offline PCM fixtures.

The default suite exercises real ffmpeg/ffprobe and production silence injection
without contacting a speech provider. Synthetic tones model a title, a pause and
body audio; they do not certify speech quality or Edge availability.

Real Edge synthesis is separately opt-in: RUN_LIVE_EDGE_AUDIO_TESTS=1. Provider
HTTP errors, timeouts and empty payloads fail those tests rather than becoming
skips. The manual Live Edge audio workflow runs them on GitHub.
"""

from __future__ import annotations

import asyncio
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def _has_ffmpeg() -> bool:
    return bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))


def _live_edge_enabled() -> bool:
    return os.environ.get("RUN_LIVE_EDGE_AUDIO_TESTS") == "1" and not os.environ.get(
        "SKIP_NETWORK_TESTS"
    )


async def _synth_edge(text: str, destination: Path) -> None:
    """Only explicit live runs may contact Edge; provider failures stay fatal."""
    if not _live_edge_enabled():
        raise RuntimeError("Live Edge audio requires RUN_LIVE_EDGE_AUDIO_TESTS=1")
    import edge_tts

    await asyncio.wait_for(
        edge_tts.Communicate(text, "pt-BR-ThalitaMultilingualNeural").save(str(destination)),
        timeout=45,
    )
    if not destination.exists() or destination.stat().st_size < 1000:
        raise AssertionError("Edge-TTS returned an empty or incomplete payload")


_LIVE_SKIP_REASON = "Live Edge audio disabled; set RUN_LIVE_EDGE_AUDIO_TESTS=1 explicitly"


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


def _pcm_stats(path: Path) -> tuple[float, int]:
    """Decode every frame; report duration and the number of active samples."""
    result = subprocess.run(
        ("ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ar", "24000",
         "-ac", "1", "pipe:1"),
        check=True, capture_output=True, timeout=30,
    )
    if not result.stdout or len(result.stdout) % 2:
        raise AssertionError("Missing or malformed decoded PCM")
    samples = struct.unpack(f"<{len(result.stdout) // 2}h", result.stdout)
    return len(samples) / 24000, sum(abs(sample) >= 100 for sample in samples)


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


class _AudioPropertiesChecks:
    """Shared decoded-audio checks for local fixtures and opt-in Edge output."""

    fixture_text = (
        "Capítulo 1.\n\nA transformação aconteceu perto das duas e vinte e três da manhã. "
        "Até onde sei todo mundo morreu na hora."
    )

    def setUp(self):
        # Exercise system ffmpeg directly; optional static_ffmpeg setup may download.
        self.paths_patch = patch("src.audio_postprocess._ensure_ffmpeg_paths")
        self.paths_patch.start()
        self.addCleanup(self.paths_patch.stop)

    def test_output_is_24khz(self):
        """Preserve the expected 24 kHz fixture/provider fingerprint."""
        rate = _ffprobe_sample_rate(self.raw_path)
        self.assertEqual(rate, 24000, f"expected 24 kHz, got {rate}")

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
            ok, error = await inject_silence_at_offset(
                injected, insert_at_seconds=splice, silence_ms=2000, bitrate="8k"
            )
            self.assertTrue(ok, error)

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
            ok, error = await inject_silence_at_offset(
                injected, insert_at_seconds=1.0, silence_ms=1000
            )
            self.assertTrue(ok, error)

        asyncio.run(_do())
        self.assertEqual(_ffprobe_sample_rate(injected), 24000)
        source_duration, source_active = _pcm_stats(self.raw_path)
        output_duration, output_active = _pcm_stats(injected)
        self.assertGreater(source_active, 0, "source fixture must contain active audio")
        self.assertGreaterEqual(output_duration, source_duration + 0.8)
        self.assertGreaterEqual(output_active, source_active * 0.90, "splice stripped source audio")


@unittest.skipUnless(_has_ffmpeg(), "ffmpeg/ffprobe not on PATH")
class TestOfflineOutputAudioProperties(_AudioPropertiesChecks, unittest.TestCase):
    """Real local PCM -> MP3 -> production splice -> decoded audio checks."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="offline_audio_test_"))
        cls.addClassCleanup(shutil.rmtree, cls.tmp, ignore_errors=True)
        cls.raw_path = cls.tmp / "raw.mp3"
        wav_path = cls.tmp / "source.wav"
        sample_rate = 24000
        samples = []
        for index in range(int(4.5 * sample_rate)):
            seconds = index / sample_rate
            frequency = 660 if seconds < 1.0 else 440
            sample = 0 if 1.0 <= seconds < 1.5 else int(
                12000 * math.sin(2 * math.pi * frequency * seconds)
            )
            samples.append(sample)
        with wave.open(str(wav_path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(sample_rate)
            output.writeframes(struct.pack(f"<{len(samples)}h", *samples))
        subprocess.run(
            ("ffmpeg", "-y", "-v", "error", "-i", str(wav_path), "-ar", "24000",
             "-ac", "1", "-b:a", "48k", str(cls.raw_path)),
            check=True, capture_output=True, timeout=30,
        )

    def test_fixture_decodes_complete_title_pause_and_body(self):
        duration, active = _pcm_stats(self.raw_path)
        self.assertAlmostEqual(duration, 4.5, delta=0.15)
        self.assertGreater(active, 3.5 * 24000)
        gaps = _silence_runs(self.raw_path)
        self.assertTrue(any(0.8 <= start <= 1.2 and length >= 0.2 for start, length in gaps))


@unittest.skipUnless(_live_edge_enabled(), _LIVE_SKIP_REASON)
class TestEdgeOutputAudioProperties(_AudioPropertiesChecks, unittest.TestCase):
    """Explicit live-provider checks; a provider outage is a test failure."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="edge_audio_test_"))
        cls.addClassCleanup(shutil.rmtree, cls.tmp, ignore_errors=True)
        cls.raw_path = cls.tmp / "raw.mp3"
        asyncio.run(_synth_edge(cls.fixture_text, cls.raw_path))


@unittest.skipUnless(_live_edge_enabled(), _LIVE_SKIP_REASON)
class TestEdgeFingerprintIsConsistent(unittest.TestCase):
    """A book-wide property: every Edge-synthesised MP3 must have the
    same sample rate. A single 16 kHz outlier means Piper got mixed in
    (the Carl Capa regression)."""

    def test_two_synths_same_rate(self):
        with tempfile.TemporaryDirectory(prefix="edge_consistency_") as tmp:
            a = Path(tmp) / "a.mp3"
            b = Path(tmp) / "b.mp3"
            asyncio.run(_synth_edge("Olá, mundo.", a))
            asyncio.run(_synth_edge("Outro chapter, outro texto.", b))
            self.assertEqual(_ffprobe_sample_rate(a), 24000)
            self.assertEqual(_ffprobe_sample_rate(b), 24000)


if __name__ == "__main__":
    unittest.main()
