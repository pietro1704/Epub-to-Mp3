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


def test_verify_prompt_uses_terminal_prompt_not_bare_input():
    """Fix for ^M appearing after the prompt when called from ./convert.

    ./convert uses tty.setcbreak() for the menu which leaves the terminal in
    cbreak mode.  Plain ``input()`` then sees CR (^M) as the line terminator
    and echoes it visibly instead of advancing the line.  The verify-mode
    prompt must use TerminalPrompt._read() which restores canonical mode
    before reading so that Enter always produces a clean newline.
    """
    src = MAIN_PY.read_text(encoding="utf-8")
    # The verify-mode prompt block must import and use TerminalPrompt._read.
    assert "TerminalPrompt" in src or "from src.ui.prompt import" in src
    # The TerminalPrompt import must appear inside the verify confirm block
    # (i.e. near the Do you want to fix string), not just at module level.
    fix_block_start = src.find("Do you want to fix the issues now?")
    assert fix_block_start != -1, "Verify prompt string not found in main.py"
    # Look back up to 600 chars before the prompt string for TerminalPrompt usage
    context = src[max(0, fix_block_start - 600) : fix_block_start + 200]
    assert "TerminalPrompt" in context or "_TP" in context, (
        "The verify confirm prompt must use TerminalPrompt, not bare input(), "
        "so that ^M from tty.setcbreak() is handled correctly."
    )
