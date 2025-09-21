# -*- coding: utf-8 -*-
"""Factory responsible for instantiating TTS engines."""

from __future__ import annotations

import pathlib
from pathlib import Path
from typing import Optional, Protocol

from ..config import ConversionConfig, VoiceConfigProvider


class TTSEngine(Protocol):
    async def synthesize_async(self, text: str, output_path: Path):  # pragma: no cover - protocol stub
        ...


class TTSFactory:
    def __init__(self) -> None:
        self.voice_provider = VoiceConfigProvider()

    def create_engine(self, config: ConversionConfig) -> TTSEngine:
        engine = (config.engine or "").lower()

        if engine == "edge":
            from .edge_engine import EdgeTTSEngine

            voice = config.voice or self.voice_provider.get_voice("edge", config.primary_language) or "pt-BR-ThalitaMultilingualNeural"
            return EdgeTTSEngine(
                voice,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
                verbose=getattr(config, 'verbose', False),
            )

        if engine == "coqui":
            from .coqui_engine import CoquiTTSEngine

            voice = config.voice or self.voice_provider.get_voice("coqui", config.primary_language)
            if not voice:
                voice = "tts_models/multilingual/multi-dataset/xtts_v2"  # Default model (Multilingual XTTS)
            return CoquiTTSEngine(
                voice,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
                verbose=getattr(config, 'verbose', False),
            )

        if engine == "piper":
            from .piper_engine import PiperTTSEngine

            model_path = config.model_path or self._find_piper_model()
            return PiperTTSEngine(
                model_path,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
            )

        raise ValueError(f"Unsupported engine: {config.engine}")

    def _find_piper_model(self, models_dir: Optional[Path] = None) -> Path:
        if models_dir is not None:
            search_dir = Path(models_dir)
        else:
            path_cls = Path
            candidate = getattr(path_cls, "return_value", None)
            if isinstance(candidate, pathlib.Path):
                search_dir = candidate
            else:
                search_dir = path_cls("models")

        if not search_dir.exists() or not search_dir.is_dir():
            raise FileNotFoundError("No models directory found for Piper")

        for candidate in sorted(search_dir.glob("*.onnx")):
            if candidate.is_file():
                return candidate

        raise FileNotFoundError("No Piper models were found")


__all__ = ["TTSFactory", "TTSEngine"]
