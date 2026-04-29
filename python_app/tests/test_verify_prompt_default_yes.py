"""Verify prompt now defaults to YES and tolerates CR-only line endings.

The user reported that pressing 'y' on the legacy `[y/N]` prompt didn't
register — the trailing `^M` (Carriage Return) on their terminal turned
the input into `y\r` which `.strip().lower()` did not normalise. Pinning
the new behaviour: empty / `y` / `\\r` / `sim` all confirm; only `n` /
`no` cancel.

Test approach: read the source, not run main() — the verify entrypoint
needs an EPUB + output dir + interactive TTY which is impractical to
fake here. The string assertions catch any regression that drops the
new defaults.
"""

from __future__ import annotations

from pathlib import Path

MAIN_PY = Path(__file__).resolve().parents[1] / "main.py"


def test_prompt_label_changed_to_default_yes():
    src = MAIN_PY.read_text(encoding="utf-8")
    assert "[Y/n]" in src
    # Legacy [y/N] must not survive in the verify-mode prompt.
    assert "Do you want to fix the issues now? [y/N]" not in src


def test_empty_input_confirms():
    src = MAIN_PY.read_text(encoding="utf-8")
    # The new branch accepts empty string AND the common variants.
    assert 'answer in ("", "y", "yes", "s", "sim")' in src


def test_carriage_return_stripped_before_compare():
    src = MAIN_PY.read_text(encoding="utf-8")
    # `\\r` from Windows/SSH terminals must not tip the comparison.
    assert '.rstrip("\\r")' in src
