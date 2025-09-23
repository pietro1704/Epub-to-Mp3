# -*- coding: utf-8 -*-
"""Application configuration utilities used by the converter."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, Optional


SUPPORTED_FORMATS = [".epub", ".pdf"]
AUDIO_FORMATS = ["mp3", "wav", "ogg"]


@dataclass
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
    parallel: Optional[int] = None  # None = sequencial, int = paralelo
    no_parallel: bool = False  # **NEW**: Desabilitar paralelismo completamente
    use_simple_converter: bool = False  # **CHANGED**: Usar conversor legado por padrão
    force_reprocess: bool = False
    listen: bool = False
    cache_dir: Optional[Path] = None
    clear_cache: bool = False
    footnote_mode: str = "inline"
    footnote_context_words: int = 8
    primary_language: str = "auto"
    languages: list[str] = field(default_factory=list)
    language_voices: Dict[str, str] = field(default_factory=dict)
    extra: Dict[str, str] = field(default_factory=dict)
    batch_size: int = 0
    verbose: bool = False

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
            "batch_size": self.batch_size,
            "force_reprocess": self.force_reprocess,
            "listen": self.listen,
            "cache_dir": str(self.cache_dir) if self.cache_dir else None,
            "clear_cache": self.clear_cache,
            "footnote_mode": self.footnote_mode,
            "footnote_context_words": self.footnote_context_words,
            "primary_language": self.primary_language,
            "languages": list(self.languages),
            "language_voices": dict(self.language_voices),
        }
        if self.extra:
            data["extra"] = dict(self.extra)
        return data


class VoiceConfigProvider:
    """Expose curated voices and models used by the CLI and tests."""

    def __init__(self) -> None:
        self._edge_voices = {
            "1": ("pt-BR-ThalitaMultilingualNeural", "Thalita – pt-BR (multilingual)"),
            "2": ("pt-BR-AntonioNeural", "Antonio – pt-BR"),
            "3": ("en-US-GuyNeural", "Guy – en-US"),
        }
        self._coqui_models = {
            "1": ("tts_models/multilingual/multi-dataset/xtts_v2", "XTTS v2", "Modelo multilingue universal", False),
            "2": ("tts_models/pt/cv/vits", "VITS pt-BR", "Modelo treinado para português", True),
        }
        self._edge_language_map = {
            "pt": "pt-BR-ThalitaMultilingualNeural",
            "en": "en-US-JennyNeural",
            "es": "es-ES-ElviraNeural",
            "fr": "fr-FR-DeniseNeural",
            "de": "de-DE-ConradNeural",
            "it": "it-IT-IsabellaNeural",
        }
        self._coqui_language_map = {
            "default": "tts_models/pt/cv/vits",
        }
        self._piper_language_map = {}

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

    def get_voice(self, engine: str, primary_language: Optional[str] = None) -> Optional[str]:
        """Return a sensible default voice/model for the given engine."""

        engine = (engine or "").lower()
        language = (primary_language or "").split('-', 1)[0].lower() or None

        if engine == "edge":
            return self._edge_voices.get("1", (None,))[0]
        if engine == "coqui":
            return self._coqui_models.get("1", (None,))[0]
        return None

    def build_language_voice_map(
        self,
        engine: str,
        languages: Iterable[str],
        fallback_voice: Optional[str],
        *,
        primary_language: Optional[str] = None,
    ) -> Dict[str, str]:
        engine = (engine or "").lower()
        mapping: Dict[str, str] = {}
        primary_code = (primary_language or "").split('-', 1)[0]
        if not primary_code and fallback_voice:
            primary_code = (languages[0] if languages else "") or ""
        valid_primary = None
        for language in languages:
            code = (language or "").split('-', 1)[0]
            if not code:
                continue
            if valid_primary is None:
                valid_primary = code
            if engine == "edge":
                voice = self._edge_language_map.get(code)
                if not voice:
                    voice = fallback_voice
                if voice:
                    mapping[code] = voice
            elif engine == "coqui":
                mapping[code] = self._coqui_language_map.get("default", fallback_voice or "coqui-tts/xtts_v2")
            elif engine == "piper":
                if fallback_voice:
                    mapping[code] = fallback_voice
        if fallback_voice and valid_primary:
            mapping.setdefault(valid_primary, fallback_voice)
        return {k: v for k, v in mapping.items() if k and v}


class AppConfig:
    """Factory responsible for producing :class:`ConversionConfig` instances."""

    def __init__(self) -> None:
        self.voice_configs = VoiceConfigProvider()

    def create_conversion_config(self, engine: str, **kwargs) -> ConversionConfig:
        """Normalise arguments into a :class:`ConversionConfig`."""

        engine = (engine or "edge").lower()
        primary_language = kwargs.pop("primary_language", None)
        languages = kwargs.pop("languages", None) or []
        voice = kwargs.pop("voice", None) or self.voice_configs.get_voice(engine, primary_language)

        model_value = kwargs.pop("model_path", None) or kwargs.pop("model", None)
        model_path = Path(model_value) if model_value else None
        cache_dir_value = kwargs.pop("cache_dir", None)
        cache_dir_path = Path(cache_dir_value) if cache_dir_value else None

        output_dir = kwargs.pop("output_dir", None) or "output"
        book_title = kwargs.pop("book_title", "")

        preserve_all = kwargs.pop("preserve_all_chapters", None)
        if preserve_all is None and "preserve_all" in kwargs:
            preserve_all = bool(kwargs.pop("preserve_all"))
        preserve_all = True if preserve_all is None else bool(preserve_all)

        bitrate = kwargs.pop("bitrate", "32k")
        sample_rate = int(kwargs.pop("sample_rate", 22_050))
        channels = int(kwargs.pop("channels", 1))
        # **CHANGED**: Paralelismo como opt-in - padrão é sequencial
        raw_parallel = kwargs.pop("parallel", None)
        if raw_parallel is None:
            raw_parallel = kwargs.pop("max_parallel", None)

        if raw_parallel is None:
            parallel = None  # **CHANGED**: None = modo sequencial
        elif raw_parallel == 0:
            # **NEW**: --parallel sem valor = auto (usar CPU count)
            import os
            cpu_count = os.cpu_count() or 4
            parallel = min(cpu_count, 8)  # Auto com limite seguro
        else:
            try:
                parallel = max(int(raw_parallel), 1)
            except (TypeError, ValueError):
                parallel = None  # **CHANGED**: Erro = modo sequencial
        force_reprocess = bool(kwargs.pop("force_reprocess", False))
        listen_flag = bool(kwargs.pop("listen", False))
        if listen_flag and parallel is not None:
            parallel = 1  # **CHANGED**: Listen força paralelo = 1
        clear_cache_flag = bool(kwargs.pop("clear_cache", False))
        footnote_mode = (kwargs.pop("footnote_mode", None) or "inline").lower()
        if footnote_mode not in {"inline", "skip", "chapter_end"}:
            footnote_mode = "inline"
        raw_context = kwargs.pop("footnote_context_words", None)
        try:
            footnote_context_words = max(int(raw_context), 0)
        except (TypeError, ValueError):
            footnote_context_words = 8
        if footnote_context_words == 0:
            footnote_context_words = 8

        language_voices = kwargs.pop("language_voices", None) or {}

        raw_batch_size = kwargs.pop("batch_size", None)
        try:
            batch_size = max(int(raw_batch_size), 1) if raw_batch_size is not None else 0
        except (TypeError, ValueError):
            batch_size = 0
        if batch_size <= 0:
            # **CHANGED**: Batch size baseado no paralelismo (ou 1 se sequencial)
            effective_parallel = parallel if parallel is not None else 1
            batch_size = max(effective_parallel * 2, effective_parallel + 1)

        # Extract new parameters
        no_parallel = bool(kwargs.pop("no_parallel", False))
        use_simple_converter = bool(kwargs.pop("use_simple_converter", False))
        verbose = bool(kwargs.pop("verbose", False))

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
            no_parallel=no_parallel,
            use_simple_converter=use_simple_converter,
            force_reprocess=force_reprocess,
            listen=listen_flag,
            cache_dir=cache_dir_path,
            clear_cache=clear_cache_flag,
            footnote_mode=footnote_mode,
            footnote_context_words=footnote_context_words,
            primary_language=(primary_language or (languages[0] if languages else "auto")),
            languages=list(languages),
            language_voices=dict(language_voices),
            batch_size=batch_size,
            verbose=verbose,
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
