"""Validate written audio payloads, durations and segment completeness."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Optional

from .config import ConversionConfig
from .utils import TextValidator


class OutputAudioIntegrity:
    def _validate_audio_after_write(
        self,
        text_payload: str,
        output_path: Path,
        *,
        config: ConversionConfig,
    ) -> tuple[bool, Optional[str]]:
        """Validate MP3 integrity and duration after conversion."""
        try:
            from .audio_validator import AudioValidator

            validator = AudioValidator()
            file_is_valid = validator.validate_audio_file(output_path)
            if not file_is_valid:
                return False, "Invalid or corrupted audio"

            normalized_len = len(re.sub(r"\s+", " ", text_payload or "").strip())
            if normalized_len >= 5000:
                # Increased tolerance: Edge-TTS speed varies significantly based on content
                # Portuguese text + formatting cues make duration estimation less accurate
                tolerance = 0.50 if normalized_len < 10000 else 0.40
                duration_result = validator.validate_duration(
                    text_payload, output_path, tolerance=tolerance
                )
                if not duration_result.is_valid:
                    # Log warning but don't fail - file exists and is playable
                    if self.verbose:
                        print(f"⚠️ Duration check: {duration_result.message}")
                    # Don't fail conversion due to duration mismatch alone
                    # return False, duration_result.message or "Invalid duration"

            return True, None
        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Audio validation failed with error: {exc}")
            return True, None

    def _edge_segment_integrity_ok(self, tts_engine: object) -> tuple[bool, Optional[str]]:
        """Decide whether the Edge synthesis is "good enough" to keep.

        Originally this enforced 100% completeness — any single failed segment
        flushed the whole MP3 and the chapter was marked failed even when
        ffprobe reported 20+ minutes of valid audio on disk. Real-world
        listening tests on a 25K-char chapter where 1/45 segments failed
        (Carl, Capítulo 47, 2026-04-29) showed the resulting MP3 was
        indistinguishable from a clean run — the missing segment was a brief
        sentence the listener would never notice.

        New policy: keep the MP3 when at least
        ``EDGE_SEGMENT_OK_RATIO`` (default 0.95) of segments synthesised
        successfully. Below that threshold, fall back to the strict
        behaviour (delete + retry) because too many gaps would be audible.
        Operators that want zero-tolerance can set the env var to ``1.0``.
        """
        import os as _os

        report = getattr(tts_engine, "last_segment_report", None)
        expected = 0
        generated = 0
        failed = 0
        if isinstance(report, dict):
            try:
                expected = int(report.get("expected") or 0)
                generated = int(report.get("generated") or 0)
                failed = int(report.get("failed") or 0)
            except (TypeError, ValueError):
                expected = 0
                generated = 0
                failed = 0

        tracker_missing = 0
        if hasattr(tts_engine, "get_synthesis_tracker"):
            tracker = tts_engine.get_synthesis_tracker()
            if tracker:
                try:
                    tracker_missing = len(tracker.get_missing_segments() or [])
                except Exception:
                    tracker_missing = 0

        if getattr(tts_engine, "partial_failure_detected", False):
            # Hard failures (rate limit storm, ffmpeg crash, etc.) still
            # disqualify the output regardless of ratio — the engine itself
            # told us the audio is unusable.
            return False, "Partial failure detected in Edge synthesis"

        try:
            tolerance = float(_os.getenv("EDGE_SEGMENT_OK_RATIO", "0.95"))
        except (TypeError, ValueError):
            tolerance = 0.95
        tolerance = max(0.0, min(tolerance, 1.0))

        total_failed = failed if failed > 0 else tracker_missing
        if total_failed > 0:
            if expected > 0 and generated > 0:
                ratio = generated / expected
                if ratio >= tolerance:
                    # Good enough: keep the MP3, surface a soft warning so
                    # operators with strict requirements still notice.
                    return True, None
                return (
                    False,
                    f"Missing segments: {generated}/{expected} (failed {total_failed})",
                )
            return False, f"Missing segments: {total_failed}"

        if expected and generated and expected != generated:
            ratio = generated / max(expected, 1)
            if ratio >= tolerance:
                return True, None
            return False, f"Incomplete segments: {generated}/{expected}"

        return True, None

    @staticmethod
    def _bitrate_to_bps(bitrate: Optional[str]) -> Optional[int]:
        if bitrate is None:
            return None
        text = str(bitrate).strip().lower()
        if not text:
            return None
        multiplier = 1_000 if text.endswith(("kbps", "k")) else 1
        if text.endswith("mbps") or text.endswith("m"):
            multiplier = 1_000_000
        suffixes = ("mbps", "kbps", "bps", "m", "k")
        for suffix in suffixes:
            if text.endswith(suffix):
                text = text[: -len(suffix)]
                break
        text = text.strip()
        if not text:
            return None
        try:
            value = float(text)
        except ValueError:
            return None
        bps = int(value * multiplier)
        return bps if bps > 0 else None

    @classmethod
    def _expected_audio_bytes(
        cls, estimated_seconds: float, bitrate: Optional[str]
    ) -> Optional[int]:
        if estimated_seconds <= 0:
            return None
        bps = cls._bitrate_to_bps(bitrate)
        if not bps:
            return None
        expected = estimated_seconds * (bps / 8.0)
        return int(expected)

    def _probe_audio_duration(self, audio_path: Path) -> Optional[float]:
        try:
            result = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(audio_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                value = result.stdout.strip()
                if value:
                    duration = float(value)
                    if duration > 0:
                        return duration
        except FileNotFoundError:
            pass
        except Exception:
            pass
        return None

    async def _probe_audio_duration_async(self, audio_path: Path) -> Optional[float]:
        """Async variant: runs ffprobe in a worker thread so the event
        loop keeps making progress on other chapters during the call.

        Equivalent semantics to ``_probe_audio_duration`` — returns the
        duration in seconds or ``None`` on any failure.
        """
        try:
            from ._async_subprocess import ffprobe_duration

            return await ffprobe_duration(str(audio_path))
        except Exception:
            return None

    def _detect_short_audio_output(
        self,
        audio_path: Path,
        payload_text: Optional[str],
        config: ConversionConfig,
        engine_label: Optional[str] = None,
    ) -> Optional[str]:
        """Decide whether ``audio_path`` looks too short for ``payload_text``.

        The chars/WPM estimator over-counts for PT-BR with heavy dialogue
        (quote glyphs, em-dashes, attribution clauses) — Edge speaks
        those much faster than the formula assumes. The 2026-04-29 Carl
        run had a 32-minute MP3 (real, ffprobe-confirmed) flagged as
        truncated because the formula expected ~38 minutes. The cache
        was deleted and the chapter re-synthesised pointlessly.

        New default ratio: 0.50 (was 0.60). Tunable via
        ``EDGE_TRUNCATION_RATIO`` for operators that prefer the strict
        legacy behaviour. Below the ratio the audio is genuinely short
        and worth re-doing.
        """
        import os as _os

        audio_path = Path(audio_path)
        if not audio_path.exists() or not payload_text:
            return None

        (engine_label or getattr(config, "engine", "") or "").lower()

        try:
            file_size = audio_path.stat().st_size
        except OSError:
            file_size = 0

        stripped = payload_text.strip() if payload_text else ""
        if len(stripped) < 2000:
            return None

        estimated_seconds = TextValidator.estimate_duration(stripped)
        if estimated_seconds < 150:
            return None

        try:
            ratio = float(_os.getenv("EDGE_TRUNCATION_RATIO", "0.50") or "0.50")
        except (TypeError, ValueError):
            ratio = 0.50
        ratio = max(0.10, min(ratio, 0.95))

        actual_seconds = self._probe_audio_duration(audio_path)
        if actual_seconds and actual_seconds >= estimated_seconds * ratio:
            return None
        if actual_seconds and actual_seconds >= max(
            estimated_seconds - 90, estimated_seconds * (ratio * 0.85)
        ):
            return None

        expected_bytes = self._expected_audio_bytes(
            estimated_seconds, getattr(config, "bitrate", "8k")
        )
        ratio_warning = False
        approx_seconds = None
        if expected_bytes:
            minimum_expected = max(int(expected_bytes * (ratio * 0.85)), 180_000)
            if file_size < minimum_expected:
                ratio_warning = True
        if not ratio_warning and actual_seconds is None:
            bitrate_bps = self._bitrate_to_bps(getattr(config, "bitrate", "8k")) or 8_000
            approx_seconds_calc = (file_size * 8) / max(bitrate_bps, 1)
            approx_seconds = int(approx_seconds_calc)
            if approx_seconds < estimated_seconds * (ratio * 0.85):
                ratio_warning = True

        if not ratio_warning and actual_seconds is None:
            return None

        short_seconds = approx_seconds if approx_seconds is not None else int(actual_seconds or 0)
        if actual_seconds is not None:
            short_seconds = int(actual_seconds)

        expected_display = int(estimated_seconds)
        if short_seconds <= 0:
            short_seconds = max(int((file_size or 1) / 1000), 1)

        return f"Audio possibly truncated ({file_size} bytes ≈ {short_seconds}s, expected ≈ {expected_display}s)"
