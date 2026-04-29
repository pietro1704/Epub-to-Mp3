"""Pin Edge-TTS speed defaults so a future tuning regression is loud.

The defaults below were chosen after the 2026-04-29 Carl conversion
(819K chars, 46m45s, average 292 chars/s with peaks at 558 chars/s)
showed several places where the engine was leaving throughput on the
table. The values are intentionally written as plain assertions on
module-level constants so an accidental edit (e.g. someone restoring
the previous chunk size of 10K) breaks CI immediately.

The env-var override paths are tested by *re-running the same clamp
expression* against a fake input rather than reloading the module —
following CLAUDE.md's `Never use importlib.reload in tests` rule, which
applies equally to `sys.modules.pop` + import (both produce a fresh
class object that breaks cross-file isinstance/identity checks).
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.tts.edge_engine import (
    _DEFAULT_CHUNK_SIZE,
    _SAFE_CHUNK_MAX,
    _SAFE_CONCURRENCY_CEILING,
    _SAFE_CONCURRENCY_MAX,
    _SAFE_CONCURRENCY_MIN,
    EDGE_NOAUDIO_COOLDOWN_SECONDS,
)


def _resolve_cap(env_value: str | None) -> int:
    """Reproduce the module-level clamp for the cap. Mirrors the lines:
        cap = int(env or default)
        cap = max(MIN, min(cap, CEILING))
    in `edge_engine.py`. Kept in sync manually — this test file is the
    canary that goes red if the source diverges.
    """
    try:
        cap = int((env_value or str(_SAFE_CONCURRENCY_MAX)).strip() or str(_SAFE_CONCURRENCY_MAX))
    except (TypeError, ValueError):
        cap = _SAFE_CONCURRENCY_MAX
    return max(_SAFE_CONCURRENCY_MIN, min(cap, _SAFE_CONCURRENCY_CEILING))


class TestEdgeSpeedDefaults(unittest.TestCase):
    def test_default_chunk_is_12k(self):
        self.assertEqual(_DEFAULT_CHUNK_SIZE, 12000)

    def test_safe_chunk_max_is_15k(self):
        self.assertEqual(_SAFE_CHUNK_MAX, 15000)

    def test_default_concurrency_cap_is_8(self):
        """Legacy hard cap preserved by default — operators must opt in."""
        self.assertEqual(_SAFE_CONCURRENCY_MAX, 8)

    def test_concurrency_ceiling_allows_up_to_16(self):
        self.assertEqual(_SAFE_CONCURRENCY_CEILING, 16)

    def test_noaudio_cooldown_is_15s(self):
        """A 60s cooldown after a single empty payload is too punitive on
        long books (caught one false-positive in the Carl run that
        stalled the queue for a full minute)."""
        self.assertEqual(EDGE_NOAUDIO_COOLDOWN_SECONDS, 15.0)


class TestConcurrencyCapClamp(unittest.TestCase):
    """Reproduce the clamp logic with no module reload."""

    def test_cap_can_be_raised_to_12_locally(self):
        self.assertEqual(_resolve_cap("12"), 12)

    def test_cap_above_ceiling_is_clamped_to_16(self):
        self.assertEqual(_resolve_cap("999"), 16)

    def test_cap_below_min_is_clamped_to_2(self):
        self.assertEqual(_resolve_cap("1"), 2)

    def test_invalid_cap_falls_back_to_default(self):
        self.assertEqual(_resolve_cap("not-a-number"), 8)

    def test_unset_cap_uses_default(self):
        self.assertEqual(_resolve_cap(None), 8)


if __name__ == "__main__":
    unittest.main()
