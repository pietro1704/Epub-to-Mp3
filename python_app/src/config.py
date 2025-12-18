# -*- coding: utf-8 -*-
"""Application configuration utilities used by the converter."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from .paths import OUTPUT_DIR, CACHE_DIR


SUPPORTED_FORMATS = [".epub", ".pdf"]
AUDIO_FORMATS = ["mp3", "wav", "ogg"]


@dataclass
class ConversionConfig:
    """Runtime configuration for an audio conversion session."""

    engine: str
    voice: Optional[str] = None
    model_path: Optional[Path] = None
    output_dir: Path = OUTPUT_DIR  # Sempre usa a raiz do projeto
    book_title: str = ""
    preserve_all_chapters: bool = True
    bitrate: str = "8k"  # Máxima compressão possível para voz (75% de redução)
    sample_rate: int = 16_000  # Suficiente para voz (Nyquist 8kHz)
    channels: int = 1  # Mono para audiobooks
    use_simple_converter: bool = False
    force_reprocess: bool = False
    listen: bool = False
    cache_dir: Path = CACHE_DIR  # Sempre usa a raiz do projeto
    clear_cache: bool = False
    footnote_mode: str = "inline"
    footnote_context_words: int = 8
    primary_language: str = "auto"
    languages: list[str] = field(default_factory=list)
    language_voices: Dict[str, str] = field(default_factory=dict)
    priority_selectors: list[str] = field(default_factory=list)
    extra: Dict[str, str] = field(default_factory=dict)
    batch_size: int = 0
    verbose: bool = False
    edge_auto_offline_seconds: int = 0  # disabled: Edge handles large chapters via chunking
    edge_auto_offline_chars: int = 0  # disabled: Edge handles large chapters via chunking
    edge_chunk_chars: int = 20000  # character budget per Edge chunk before splitting (optimized: 20K)
    edge_max_segment_seconds: int = 75  # hard limit for each Edge chunk duration (optimized: 75s)
    edge_aggressive_mode: bool = False
    edge_enable_parallel: bool = True  # enable parallel segment processing (5-6x faster)

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
            "priority_selectors": list(self.priority_selectors),
            "edge_auto_offline_seconds": self.edge_auto_offline_seconds,
            "edge_auto_offline_chars": self.edge_auto_offline_chars,
            "edge_chunk_chars": self.edge_chunk_chars,
            "edge_max_segment_seconds": self.edge_max_segment_seconds,
            "edge_enable_parallel": self.edge_enable_parallel,
        }
        if self.extra:
            data["extra"] = dict(self.extra)
        return data


class VoiceConfigProvider:
    """Expose curated voices and models used by the CLI and tests."""

    def __init__(self) -> None:
        self._edge_voice_catalog: List[Dict[str, object]] = [
            {"id": "pt-BR-ThalitaMultilingualNeural", "label": "Thalita – pt-BR (multilingual)", "multilingual": True, "language": "pt-BR"},
            {"id": "pt-BR-FranciscaNeural", "label": "Francisca – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-AntonioNeural", "label": "Antonio – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-BrendaNeural", "label": "Brenda – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-ElzaNeural", "label": "Elza – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-GiovannaNeural", "label": "Giovanna – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-LeilaNeural", "label": "Leila – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-LeticiaNeural", "label": "Leticia – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-ManuelaNeural", "label": "Manuela – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-YaraNeural", "label": "Yara – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-DonatoNeural", "label": "Donato – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-FabioNeural", "label": "Fabio – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-HumbertoNeural", "label": "Humberto – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-JulioNeural", "label": "Julio – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-NicolauNeural", "label": "Nicolau – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "pt-BR-ValerioNeural", "label": "Valerio – pt-BR", "multilingual": False, "language": "pt-BR"},
            {"id": "en-US-JennyNeural", "label": "Jenny – en-US", "multilingual": False, "language": "en-US"},
            {"id": "es-ES-ElviraNeural", "label": "Elvira – es-ES", "multilingual": False, "language": "es-ES"},
        ]
        self._edge_voices = {
            str(index): (entry["id"], entry["label"])
            for index, entry in enumerate(self._edge_voice_catalog, start=1)
        }
        self._coqui_model_catalog: List[Dict[str, object]] = [
            {"id": "tts_models/multilingual/multi-dataset/xtts_v2", "label": "XTTS v2", "description": "Modelo multilingue universal", "multilingual": True, "low_resource": False},
            {"id": "tts_models/pt/cv/vits", "label": "VITS pt-BR", "description": "Modelo otimizado para português", "multilingual": False, "low_resource": True},
            {"id": "tts_models/multilingual/multi-dataset/xtts_v1", "label": "XTTS v1", "description": "Modelo compatível com GPU antiga", "multilingual": True, "low_resource": False},
        ]
        self._coqui_models = {
            str(index): (
                entry["id"],
                entry["label"],
                entry.get("description", ""),
                bool(entry.get("low_resource")),
            )
            for index, entry in enumerate(self._coqui_model_catalog, start=1)
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
            "pt": "tts_models/pt/cv/vits",
        }
        self._coqui_default_voice = "tts_models/multilingual/multi-dataset/xtts_v2"
        self._piper_language_map = {
            "pt": "pt_BR",
            "en": "en_US",
        }
        self._piper_model_catalog: List[Dict[str, object]] = [
            {"id": "pt_BR-faber-medium.onnx", "label": "Faber medium (pt-BR)", "language": "pt-BR", "multilingual": False},
            {"id": "pt_BR-edresson-low.onnx", "label": "Edresson low (pt-BR)", "language": "pt-BR", "multilingual": False},
            {"id": "en_US-lessac-medium.onnx", "label": "Lessac medium (en-US)", "language": "en-US", "multilingual": False},
        ]
        self._auto_voice_catalog = [
            {"id": "pt-BR-ThalitaMultilingualNeural", "label": "Edge Thalita (auto)", "multilingual": True, "language": "pt-BR"},
            {"id": "tts_models/pt/cv/vits", "label": "Coqui VITS (auto)", "multilingual": False, "language": "pt-BR"},
            {"id": "tts_models/multilingual/multi-dataset/xtts_v2", "label": "XTTS v2 (auto)", "multilingual": True, "language": "multi"},
        ]

    @property
    def edge_voices(self) -> Dict[str, tuple[str, str]]:
        return dict(self._edge_voices)

    @property
    def coqui_models(self) -> Dict[str, tuple[str, str, str, bool]]:
        return dict(self._coqui_models)

    def get_voice_suggestions(self) -> Dict[str, List[Dict[str, object]]]:
        """
        Return curated voice/model suggestions grouped by engine.
        Structure is simple so the frontend can show hints dynamically.
        """
        def clone(entries: List[Dict[str, object]]) -> List[Dict[str, object]]:
            return [
                {
                    "id": entry.get("id"),
                    "label": entry.get("label"),
                    "multilingual": bool(entry.get("multilingual")),
                    "language": entry.get("language"),
                    "description": entry.get("description"),
                }
                for entry in entries
            ]

        piper_entries: List[Dict[str, object]] = []
        for entry in self._piper_model_catalog:
            candidate = dict(entry)
            candidate["id"] = entry["id"]
            candidate["label"] = entry["label"]
            candidate["multilingual"] = bool(entry.get("multilingual"))
            candidate["language"] = entry.get("language")
            piper_entries.append(candidate)

        return {
            "edge": clone(self._edge_voice_catalog),
            "coqui": clone(self._coqui_model_catalog),
            "piper": piper_entries,
            "auto": clone(self._auto_voice_catalog),
        }

    def get_piper_models(self, models_dir: Optional[Path] = None) -> Dict[str, Dict[str, object]]:
        """Discover Piper models from the configured or default locations."""

        candidate_dirs = []
        env_dir = os.getenv("PIPER_MODEL_DIR")
        if env_dir:
            candidate_dirs.append(Path(env_dir))
        if models_dir is not None:
            candidate_dirs.append(Path(models_dir))

        candidate_dirs.append(Path("models"))
        candidate_dirs.append(Path.cwd() / "models")
        python_root = Path(__file__).resolve().parents[1]
        candidate_dirs.append(python_root / "models")

        directory = next((path for path in dict.fromkeys(candidate_dirs) if path.exists() and path.is_dir()), None)
        if directory is None:
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
            code = (primary_language or "").split("-", 1)[0].lower()
            if code == "pt":
                return self._coqui_language_map.get("pt", self._coqui_default_voice)
            return self._coqui_default_voice
        if engine == "auto":
            if language == "pt":
                return self._coqui_language_map.get("pt", self._edge_voices.get("1", (None,))[0])
            return self._edge_voices.get("1", (None,))[0]
        if engine == "piper":
            code = (primary_language or "").split("-", 1)[0].lower()
            return self._resolve_piper_model(code)
        return None

    def _resolve_piper_model(self, code: str) -> Optional[str]:
        discovered = self.get_piper_models()
        if not discovered:
            return None

        prefix = self._piper_language_map.get(code, "")
        candidates = [
            entry for name, entry in discovered.items()
            if prefix and str(name).lower().startswith(prefix.lower())
        ]
        if not candidates:
            candidates = list(discovered.values())

        recommended = [c for c in candidates if c.get("recommended")]
        picked = (recommended[0] if recommended else candidates[0]) if candidates else None
        path = picked.get("path") if isinstance(picked, dict) else None
        return str(path) if path else None

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
                voice = self._coqui_language_map.get(code) or fallback_voice or self._coqui_default_voice
                if voice:
                    mapping[code] = voice
            elif engine == "auto":
                voice = self._coqui_language_map.get(code) or self._edge_language_map.get(code) or fallback_voice
                if voice:
                    mapping[code] = voice
            elif engine == "piper":
                model_path = self._resolve_piper_model(code)
                if model_path:
                    mapping[code] = model_path
                elif fallback_voice:
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
        voice_arg = kwargs.pop("voice", None)
        voice = voice_arg or self.voice_configs.get_voice(engine, primary_language)

        model_value = kwargs.pop("model_path", None) or kwargs.pop("model", None)
        model_path = Path(model_value) if model_value else None

        # Cache dir: se fornecido, usa o caminho fornecido; senão, usa CACHE_DIR da raiz
        cache_dir_value = kwargs.pop("cache_dir", None)
        cache_dir_path = Path(cache_dir_value) if cache_dir_value else CACHE_DIR

        # Output dir: se fornecido, usa o caminho fornecido; senão, usa OUTPUT_DIR da raiz
        output_dir_value = kwargs.pop("output_dir", None)
        output_dir = Path(output_dir_value) if output_dir_value else OUTPUT_DIR
        book_title = kwargs.pop("book_title", "")

        preserve_all = kwargs.pop("preserve_all_chapters", None)
        if preserve_all is None and "preserve_all" in kwargs:
            preserve_all = bool(kwargs.pop("preserve_all"))
        preserve_all = True if preserve_all is None else bool(preserve_all)

        bitrate = kwargs.pop("bitrate", "8k")  # 8k para máxima compressão (audiobooks)
        sample_rate = int(kwargs.pop("sample_rate", 16_000))  # 16kHz suficiente para voz
        channels = int(kwargs.pop("channels", 1))  # Mono para audiobooks
        force_reprocess = bool(kwargs.pop("force_reprocess", False))
        listen_flag = bool(kwargs.pop("listen", False))
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
        priority_selectors = kwargs.pop("priority_selectors", None) or []

        raw_batch_size = kwargs.pop("batch_size", None)
        try:
            batch_size = max(int(raw_batch_size), 1) if raw_batch_size is not None else 0
        except (TypeError, ValueError):
            batch_size = 0
        if batch_size <= 0:
            batch_size = 1

        # Extract new parameters
        use_simple_converter = bool(kwargs.pop("use_simple_converter", False))
        verbose = bool(kwargs.pop("verbose", False))
        def _safe_int(env_value: Optional[str], default: int) -> int:
            try:
                parsed = int(env_value) if env_value is not None else default
            except (TypeError, ValueError):
                parsed = default
            return max(parsed, 0)

        edge_auto_offline_seconds = kwargs.pop(
            "edge_auto_offline_seconds",
            _safe_int(os.getenv("EDGE_AUTO_OFFLINE_SECONDS"), ConversionConfig.edge_auto_offline_seconds),
        )
        edge_auto_offline_chars = kwargs.pop(
            "edge_auto_offline_chars",
            _safe_int(os.getenv("EDGE_AUTO_OFFLINE_CHARS"), ConversionConfig.edge_auto_offline_chars),
        )
        edge_chunk_chars = kwargs.pop(
            "edge_chunk_chars",
            _safe_int(os.getenv("EDGE_CHUNK_CHARS"), ConversionConfig.edge_chunk_chars),
        )
        edge_max_segment_seconds = kwargs.pop(
            "edge_max_segment_seconds",
            _safe_int(os.getenv("EDGE_MAX_SEGMENT_SECONDS"), ConversionConfig.edge_max_segment_seconds),
        )
        edge_enable_parallel = kwargs.pop(
            "edge_enable_parallel",
            os.getenv("EDGE_ENABLE_PARALLEL", "true").lower() in ("true", "1", "yes"),
        )

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
            priority_selectors=list(priority_selectors),
            batch_size=batch_size,
            verbose=verbose,
            edge_auto_offline_seconds=edge_auto_offline_seconds,
            edge_auto_offline_chars=edge_auto_offline_chars,
            edge_chunk_chars=edge_chunk_chars,
            edge_max_segment_seconds=edge_max_segment_seconds,
            edge_enable_parallel=edge_enable_parallel,
        )

        if kwargs:
            config.extra.update({str(key): str(value) for key, value in kwargs.items()})

        config.extra.setdefault("voice_auto", "1" if voice_arg is None else "0")

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
