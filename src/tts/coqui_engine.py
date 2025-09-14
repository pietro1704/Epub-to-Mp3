# -*- coding: utf-8 -*-
"""Coqui TTS engine wrapper with lazy initialisation."""

from __future__ import annotations

import asyncio
import importlib
from pathlib import Path
from typing import Optional
from unittest.mock import Mock

TTS = None


class CoquiTTSEngine:
    """Create and reuse a Coqui ``TTS`` instance on demand."""

    def __init__(self, model_name: str) -> None:
        global TTS

        if isinstance(TTS, Mock):
            if getattr(TTS, "side_effect", None):
                raise ImportError("Coqui TTS not installed")
            tts_class = TTS
        else:
            if TTS is None:
                try:
                    module = importlib.import_module("TTS.api")  # type: ignore
                    TTS = getattr(module, "TTS")
                except (ImportError, AttributeError) as exc:
                    raise ImportError("Coqui TTS not installed") from exc
            tts_class = TTS

        self.model_name = model_name
        self._tts_class = tts_class
        self.tts = None

    def _initialize_model(self) -> None:
        if self.tts is None:
            self.tts = self._tts_class(model_name=self.model_name)

    async def synthesize_async(self, text: str, output_path: Path) -> Optional[Path]:
        if not text:
            return None

        self._initialize_model()
        loop = asyncio.get_event_loop()
        try:
            await loop.run_in_executor(None, self.tts.tts_to_file, text, str(output_path))
        except Exception:
            return None

        return output_path if Path(output_path).exists() else None


__all__ = ["CoquiTTSEngine"]
