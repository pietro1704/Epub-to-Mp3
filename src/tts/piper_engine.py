# -*- coding: utf-8 -*-
"""Piper CLI wrapper used for offline synthesis."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Optional


class PiperTTSEngine:
    """Invoke the Piper binary with the configured model."""

    def __init__(self, model_path: Path) -> None:
        self.model_path = Path(model_path)
        if not self.model_path.exists():
            raise FileNotFoundError(f"Model not found: {self.model_path}")

    async def synthesize_async(self, text: str, output_path: Path) -> Optional[Path]:
        if not text:
            return None

        command = (
            "piper",
            "--model",
            str(self.model_path),
            "--output_file",
            str(output_path),
        )

        try:
            process = await asyncio.create_subprocess_exec(
                *command,
                stdin=asyncio.subprocess.PIPE,
            )
            await process.communicate(input=text.encode("utf-8"))
        except Exception:
            return None

        if process.returncode != 0:
            return None

        return output_path if Path(output_path).exists() else None


__all__ = ["PiperTTSEngine"]
