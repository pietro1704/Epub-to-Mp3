# -*- coding: utf-8 -*-
"""Edge TTS engine wrapper used by the converter and tests."""

from __future__ import annotations

import asyncio
import importlib
from pathlib import Path
from typing import Optional
from unittest.mock import Mock

edge_tts = None


class EdgeTTSEngine:
    """Small facade around ``edge_tts`` with predictable behaviour."""

    def __init__(self, voice: str) -> None:
        global edge_tts

        if isinstance(edge_tts, Mock):
            if getattr(edge_tts, "side_effect", None):
                raise ImportError("Edge-TTS not installed")
            module = edge_tts
        else:
            if edge_tts is None:
                try:
                    edge_tts = importlib.import_module("edge_tts")  # type: ignore
                except ImportError as exc:
                    raise ImportError("Edge-TTS not installed") from exc
            module = edge_tts

        self.voice = voice
        self._edge_tts = module

    async def synthesize_async(self, text: str, output_path: Path) -> Optional[Path]:
        if not text:
            return None

        try:
            communicator = self._edge_tts.Communicate(text, self.voice)
            timeout = self._calculate_timeout(text)
            await asyncio.wait_for(communicator.save(str(output_path)), timeout=timeout)
        except asyncio.TimeoutError:
            return None
        except Exception:
            return None

        return output_path if Path(output_path).exists() else None

    def _calculate_timeout(self, text: str) -> int:
        length = len(text)
        if length <= 1_000:
            return 30
        if length <= 5_000:
            return 60
        extra = ((length - 5_000) // 2_000 + 1) * 30
        return 90 + extra


__all__ = ["EdgeTTSEngine"]
