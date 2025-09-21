# -*- coding: utf-8 -*-
"""Application configuration utilities used by the converter."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Optional


SUPPORTED_FORMATS = [".epub", ".pdf"]
AUDIO_FORMATS = ["mp3", "wav", "ogg"]


@dataclass(slots=True)
class ConversionConfig:
    """Runtime configuration for an audio conversion session."""

    engine: str
    voice: Optional[str] = None
    model_path: Optional[Path] = None
    output_dir: str = "output"
    book_title: str = ""
    preserve_all_chapters: bool = True
    bitrate: str = "32k"
    sample_rate: int = 22_050
    channels: int = 1
    parallel: int = 1
    force_reprocess: bool = False
    listen: bool = False
    extra: Dict[str, str] = field(default_factory=dict)

    def as_dict(self) -> Dict[str, object]:
        """Return a serialisable representation useful for debugging."""
        data: Dict[str, object] = {
            "engine": self.engine,
            "voice": self.voice,
            "model_path": str(self.model_path) if self.model_path else None,
            "output_dir": self.output_dir,
            "book_title": self.book_title,
            "preserve_all_chapters": self.preserve_all_chapters,
            "bitrate": self.bitrate,
            "sample_rate": self.sample_rate,
            "channels": self.channels,
            "parallel": self.parallel,
            "force_reprocess": self.force_reprocess,
            "listen": self.listen,
        }
        if self.extra:
            data["extra"] = dict(self.extra)
        return data


class VoiceConfigProvider:
    """Expose curated voices and models used by the CLI and tests."""

    def __init__(self) -> None:
        self._edge_voices = {
            "1": ("pt-BR-FranciscaNeural", "Francisca – pt-BR (calma)"),
            "2": ("pt-BR-AntonioNeural", "Antonio – pt-BR"),
            "3": ("en-US-GuyNeural", "Guy – en-US"),
        }
        self._coqui_models = {
            "1": ("coqui-tts/xtts_v2", "XTTS v2", "Modelo multilingue universal", True),
            "2": ("coqui-tts/vits_pt_br", "VITS pt-BR", "Modelo treinado para português", False),
        }

    @property
    def edge_voices(self) -> Dict[str, tuple[str, str]]:
        return dict(self._edge_voices)

    @property
    def coqui_models(self) -> Dict[str, tuple[str, str, str, bool]]:
        return dict(self._coqui_models)

    def get_piper_models(self, models_dir: Optional[Path] = None) -> Dict[str, Dict[str, object]]:
        """Discover Piper models in ``models_dir`` (or ``./models``)."""

        directory = Path(models_dir or Path.cwd() / "models")
        if not directory.exists() or not directory.is_dir():
            return {}

        discovered: Dict[str, Dict[str, object]] = {}
        for path in sorted(directory.glob("*.onnx")):
            name = path.stem
            discovered[name] = {
                "name": name,
                "path": path,
                "recommended": name.lower().startswith("faber"),
            }
        return discovered

    def get_voice(self, engine: str) -> Optional[str]:
        """Return a sensible default voice/model for the given engine."""

        engine = (engine or "").lower()
        if engine == "edge":
            # Prefer Antonio for Portuguese narration.
            return self._edge_voices.get("2", (None,))[0]
        if engine == "coqui":
            return self._coqui_models.get("1", (None,))[0]
        return None


class AppConfig:
    """Factory responsible for producing :class:`ConversionConfig` instances."""

    def __init__(self) -> None:
        self.voice_configs = VoiceConfigProvider()

    def create_conversion_config(self, engine: str, **kwargs) -> ConversionConfig:
        """Normalise arguments into a :class:`ConversionConfig`."""

        engine = (engine or "edge").lower()
        voice = kwargs.pop("voice", None) or self.voice_configs.get_voice(engine)

        model_value = kwargs.pop("model_path", None) or kwargs.pop("model", None)
        model_path = Path(model_value) if model_value else None

        output_dir = kwargs.pop("output_dir", None) or "output"
        book_title = kwargs.pop("book_title", "")

        preserve_all = kwargs.pop("preserve_all_chapters", None)
        if preserve_all is None and "preserve_all" in kwargs:
            preserve_all = bool(kwargs.pop("preserve_all"))
        preserve_all = True if preserve_all is None else bool(preserve_all)

        bitrate = kwargs.pop("bitrate", "32k")
        sample_rate = int(kwargs.pop("sample_rate", 22_050))
        channels = int(kwargs.pop("channels", 1))
        cpu_default = max(os.cpu_count() or 1, 1)
        raw_parallel = kwargs.pop("parallel", None)
        if raw_parallel is None:
            raw_parallel = kwargs.pop("max_parallel", None)

        if raw_parallel is None:
            parallel = cpu_default
        else:
            try:
                parallel = max(int(raw_parallel), 1)
            except (TypeError, ValueError):
                parallel = cpu_default
        force_reprocess = bool(kwargs.pop("force_reprocess", False))
        listen_flag = bool(kwargs.pop("listen", False))
        if listen_flag:
            parallel = 1

        config = ConversionConfig(
            engine=engine,
            voice=voice,
            model_path=model_path,
            output_dir=output_dir,
            book_title=book_title,
            preserve_all_chapters=preserve_all,
            bitrate=bitrate,
            sample_rate=sample_rate,
            channels=channels,
            parallel=parallel,
            force_reprocess=force_reprocess,
            listen=listen_flag,
        )

        if kwargs:
            config.extra.update({str(key): str(value) for key, value in kwargs.items()})

        return config


DEFAULT_CONFIG = ConversionConfig(
    engine="edge",
    voice="pt-BR-AntonioNeural",
)


__all__ = [
    "ConversionConfig",
    "VoiceConfigProvider",
    "AppConfig",
    "DEFAULT_CONFIG",
    "SUPPORTED_FORMATS",
    "AUDIO_FORMATS",
]
