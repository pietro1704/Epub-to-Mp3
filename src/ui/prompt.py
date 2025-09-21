# -*- coding: utf-8 -*-
"""Terminal input helpers tailored for interactive menus."""

from __future__ import annotations

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
        self._supports_termios = bool(termios and tty and self._stdin.isatty() and self._stdout.isatty())

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

    # Internal helpers ---------------------------------------------------
    def _read(self, prompt: str) -> PromptResult:
        if not self._supports_termios:
            return self._fallback_read(prompt)
        return self._termios_read(prompt)

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
