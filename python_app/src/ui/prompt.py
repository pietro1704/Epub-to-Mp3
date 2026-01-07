# -*- coding: utf-8 -*-
"""Terminal input helpers tailored for interactive menus."""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import Iterable, Optional

try:  # pragma: no cover - platform dependent
    import termios  # type: ignore
    import tty  # type: ignore
except ImportError:  # pragma: no cover - Windows fallback
    termios = None  # type: ignore
    tty = None  # type: ignore


@dataclass
class PromptResult:
    """Container storing the raw input captured from the terminal."""

    text: str
    eof: bool = False


class TerminalPrompt:
    """Robust prompt reader that treats CR (``^M``) as a valid newline."""

    def __init__(self) -> None:
        self._stdin = sys.stdin
        self._stdout = sys.stdout
        force_tty = os.getenv("MENU_FORCE_TTY", "").strip().lower() in {"1", "true", "yes", "on"}
        # Prefer termios when available; if it fails we fall back gracefully below.
        self._supports_termios = bool(termios and tty) or force_tty

    # Public API ---------------------------------------------------------
    def ask(
        self,
        prompt: str,
        *,
        valid: Optional[Iterable[str]] = None,
        default: Optional[str] = None,
        allow_blank_default: bool = True,
        digits_only: bool = False,
    ) -> Optional[str]:
        """Display ``prompt`` and return the chosen value.

        ``valid`` restricts accepted answers. ``default`` is used when the
        answer is blank and ``allow_blank_default`` is True.
        When ``digits_only`` is True, only ``0-9`` characters are retained.
        Returns ``None`` when the result is empty and no default applies.
        """

        raw_value = self._read(prompt)
        if raw_value.eof:
            raise EOFError

        value = raw_value.text
        if digits_only:
            value = "".join(ch for ch in value if ch.isdigit())
        else:
            value = value.strip()

        if not value:
            if allow_blank_default and default is not None:
                value = default
            else:
                return None

        if valid is not None:
            valid_set = {str(v) for v in valid}
            if value not in valid_set:
                return None

        return value

    def select(
        self,
        prompt: str,
        options: list[tuple[str, str]],
        *,
        default_index: int = 0,
    ) -> Optional[str]:
        """
        Render a simple selector that supports:
        - Up/Down arrows + Enter
        - Typing a digit to select immediately (no Enter required)
        Falls back to ``ask`` when termios is unavailable.
        """
        if not options:
            return None

        # Fallback: plain prompt
        if not self._supports_termios:
            default_key = options[default_index][0] if 0 <= default_index < len(options) else None
            valid_keys = [key for key, _ in options]
            return self.ask(
                prompt,
                valid=valid_keys,
                allow_blank_default=True,
                default=default_key,
                digits_only=True,
            )

        assert termios is not None and tty is not None  # For type checking
        try:
            fd = self._stdin.fileno()
            old_settings = termios.tcgetattr(fd)
        except Exception:
            default_key = options[default_index][0] if 0 <= default_index < len(options) else None
            valid_keys = [key for key, _ in options]
            return self.ask(
                prompt,
                valid=valid_keys,
                allow_blank_default=True,
                default=default_key,
                digits_only=True,
            )

        index = max(0, min(default_index, len(options) - 1))

        def render() -> None:
            self._stdout.write("\n")
            self._stdout.write(prompt + "\n")
            for i, (key, label) in enumerate(options):
                prefix = "▶" if i == index else " "
                self._stdout.write(f" {prefix} {key}. {label}\n")
            self._stdout.write("Use ↑/↓ or type number. Enter to confirm.\n")
            self._stdout.write(f"Current: {options[index][1]}\n")
            self._stdout.flush()

        try:
            tty.setcbreak(fd)
            render()
            while True:
                ch = self._stdin.read(1)
                if ch == "":
                    return None
                if ch in ("\r", "\n"):
                    return options[index][0]
                if ch.isdigit():
                    key = ch
                    for opt_key, _ in options:
                        if opt_key == key:
                            self._stdout.write(f"\n→ {key}\n")
                            self._stdout.flush()
                            return key
                    continue
                if ch == "\x03":
                    raise KeyboardInterrupt
                if ch == "\x04":
                    return None
                if ch == "\x1b":
                    seq = ""
                    # Consume CSI/SS3 sequence fully (tmux/alacritty can send \x1b[1;5A, \x1bOA, etc.)
                    while True:
                        nxt = self._stdin.read(1)
                        if nxt == "":
                            break
                        seq += nxt
                        if nxt.isalpha():
                            break
                        if len(seq) > 6:
                            break
                    if seq.endswith("A"):  # Up
                        index = (index - 1) % len(options)
                        render()
                        continue
                    if seq.endswith("B"):  # Down
                        index = (index + 1) % len(options)
                        render()
                        continue
                    continue
        finally:
            try:
                termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
            except Exception:
                pass

    # Internal helpers ---------------------------------------------------
    def _read(self, prompt: str) -> PromptResult:
        if not self._supports_termios:
            return self._fallback_read(prompt)
        try:
            return self._termios_read(prompt)
        except Exception:
            return self._fallback_read(prompt)

    def wait_for_enter(self, prompt: str) -> None:
        try:
            end = "" if prompt.endswith("\n") else "\n"
            print(prompt, end=end, flush=True)
            _ = input()
        except EOFError:
            raise

    def _fallback_read(self, prompt: str) -> PromptResult:
        try:
            value = input(prompt)
        except EOFError:
            return PromptResult(text="", eof=True)
        return PromptResult(text=value.rstrip("\r\n"))

    def _termios_read(self, prompt: str) -> PromptResult:
        assert termios is not None and tty is not None  # For type checking

        fd = self._stdin.fileno()
        old_settings = termios.tcgetattr(fd)
        buffer: list[str] = []

        self._stdout.write(prompt)
        self._stdout.flush()

        eof = False

        try:
            tty.setcbreak(fd)  # read each char as typed
            while True:
                ch = self._stdin.read(1)
                if ch == "":  # EOF
                    eof = True
                    break
                if ch in ("\r", "\n"):
                    self._stdout.write("\n")
                    self._stdout.flush()
                    break
                if ch in ("\x03",):  # Ctrl-C
                    raise KeyboardInterrupt
                if ch in ("\x04",):  # Ctrl-D
                    eof = True
                    break
                if ch in ("\x7f", "\b"):  # Backspace/delete
                    if buffer:
                        buffer.pop()
                        self._stdout.write("\b \b")
                        self._stdout.flush()
                    continue
                buffer.append(ch)
                self._stdout.write(ch)
                self._stdout.flush()
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

        return PromptResult(text="".join(buffer).strip(), eof=eof)


__all__ = ["TerminalPrompt", "PromptResult"]
