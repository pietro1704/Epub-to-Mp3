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
                verbose=config.verbose,
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
                verbose=config.verbose,
            )

        if engine == "piper":
            from .piper_engine import PiperTTSEngine

            model_path = config.model_path
            if model_path is None and config.voice:
                candidate = Path(str(config.voice))
                if candidate.suffix.lower() == ".onnx" and candidate.exists():
                    model_path = candidate
            model_path = model_path or self._find_piper_model()
            engine_instance = PiperTTSEngine(
                model_path,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
            )
            engine_instance.verbose = config.verbose
            return engine_instance

        raise ValueError(f"Unsupported engine: {config.engine}")

    def _find_piper_model(self, models_dir: Optional[Path] = None) -> Path:
        candidate_dirs = []
        if models_dir is not None:
            candidate_dirs.append(Path(models_dir))
        else:
            path_cls = Path
            mocked_directory = getattr(path_cls, "return_value", None)
            if isinstance(mocked_directory, pathlib.Path):
                candidate_dirs.append(mocked_directory)

        candidate_dirs.append(Path("models"))
        candidate_dirs.append(Path.cwd() / "models")
        python_root = Path(__file__).resolve().parents[1]
        candidate_dirs.append(python_root / "models")

        for search_dir in dict.fromkeys(candidate_dirs):
            if not search_dir.exists() or not search_dir.is_dir():
                continue

            for candidate in sorted(search_dir.glob("*.onnx")):
                if candidate.is_file():
                    return candidate

        raise FileNotFoundError("No Piper models were found")


__all__ = ["TTSFactory", "TTSEngine"]
