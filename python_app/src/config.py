# -*- coding: utf-8 -*-
"""Application configuration utilities used by the converter."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional

from .paths import CACHE_DIR, OUTPUT_DIR

SUPPORTED_FORMATS = [".epub", ".pdf"]
AUDIO_FORMATS = ["mp3", "wav", "ogg"]


@dataclass
class ConversionConfig:
    """Runtime configuration for an audio conversion session."""

    engine: str
    job_id: Optional[str] = None
    voice: Optional[str] = None
    model_path: Optional[Path] = None
    output_dir: Path = OUTPUT_DIR  # Always uses project root
    book_title: str = ""
    preserve_all_chapters: bool = True
    bitrate: str = "8k"  # Maximum compression for voice (75% reduction)
    sample_rate: int = 16_000  # Sufficient for voice (Nyquist 8kHz)
    channels: int = 1  # Mono for audiobooks
    use_simple_converter: bool = False
    force_reprocess: bool = False
    listen: bool = False
    cache_dir: Path = CACHE_DIR  # Always uses project root
    clear_cache: bool = False
    footnote_mode: str = "inline"
    footnote_context_words: int = 8
    primary_language: str = "auto"
    languages: list[str] = field(default_factory=list)
    language_voices: Dict[str, str] = field(default_factory=dict)
    priority_selectors: list[str] = field(default_factory=list)
    use_language_detection: bool = True  # **NEW**: Enable automatic language detection
    prioritize_primary_language: bool = True  # **NEW**: Prioritize primary language in ambiguities
    extra: Dict[str, str] = field(default_factory=dict)
    batch_size: int = 0
    verbose: bool = False
    # Run validate_book at the end of every conversion and re-synthesise
    # any chapter that comes back missing/short/duplicated. Was opt-in
    # before v0.3.14; the user explicitly asked the app to "detect errors
    # and fix automatically" after a Carl conversion missed chapter 7.20.
    # Operators can opt out with `--no-auto-validate-output` when
    # iterating quickly (the full-book validation adds ~30s to a long
    # book) or via `AUTO_VALIDATE_OUTPUT=0` in the environment.
    auto_validate_output: bool = True
    auto_fix_output: bool = True  # Auto-reconvert (cache clean) if validation fails
    validate_text: bool = True  # Validate parsed/pre-tts text during conversion
    validate_audio: bool = True  # Validate MP3 integrity/duration after synthesis
    strict_validate: bool = False  # Stop conversion when validation fails
    deep_validate: bool = False  # Run expensive deep validation after conversion
    log_callback: Optional[Callable[[str], None]] = None  # Callback for verbose logging
    edge_auto_offline_seconds: int = 0  # disabled: Edge handles large chapters via chunking
    edge_auto_offline_chars: int = 0  # disabled: Edge handles large chapters via chunking
    # Performance-optimized settings (Jan 2026):
    # Aggressive throughput target: 200+ chars/s with higher concurrency/segment sizes.
    edge_chunk_chars: int = 12000  # Aggressive default for max throughput
    edge_max_segment_seconds: int = 85
    edge_aggressive_mode: bool = False
    edge_auto_tune: Optional[bool] = None
    edge_enable_parallel: bool = True
    edge_max_concurrency: int = 12  # Aggressive: saturate network with parallel requests
    prefer_monolingual_edge: Optional[bool] = None  # Signals when to prefer mono voices
    auto_prefer_piper: bool = False  # Auto-mode hint: Piper was benchmarked faster
    coqui_chunk_chars: Optional[int] = None  # override Coqui chunk size when auto-tuning
    coqui_max_workers: Optional[int] = None  # override Coqui worker pool size
    coqui_safe_mode: Optional[bool] = None  # force safe mode for Coqui (limits parallelism)
    piper_max_procs: Optional[int] = None  # override Piper concurrent process limit
    piper_chunk_chars: Optional[int] = None  # override Piper chunk size when auto-tuning
    engine_chain_fallback: Optional[bool] = (
        None  # mirrors ENGINE_CHAIN_FALLBACK env var; when True, legacy Edge→Kokoro→Piper cascade is re-enabled
    )
    speak_formatting_cues: bool = True
    formatting_locale: str = "pt"
    # Validation settings
    verify_transcription: bool = False
    transcription_model: str = "medium"
    validation_language: Optional[str] = None  # Language for transcription validation
    # Audio polish: silence padding applied after synthesis (ffmpeg adelay/apad).
    # 300 ms intro gives the listener a beat of breathing room before the
    # narrator starts — without it Edge-TTS tends to begin the chapter
    # immediately on hitting play, which sounds abrupt after the title
    # announcement of the previous chapter trails off. 500 ms outro keeps
    # consistent spacing between back-to-back chapters when concatenated.
    chapter_intro_silence_ms: int = 300
    chapter_outro_silence_ms: int = 500
    # Optional ffmpeg silence injection between the chapter title and
    # the body. Off by default (the user found a fixed-length pause
    # awkward — too uniform across chapters of varying length).
    # Set via the CLI's `--inject-title-pause MS` flag.
    inject_title_pause_ms: int = 0
    # Multi-voice narration: when enabled, dialogue (text inside quotes or
    # em-dash lines) is synthesised with `character_voice` while everything
    # else uses `narrator_voice`. Falls back to `voice` when either slot is
    # empty. Enabled by default — engines that don't support per-segment
    # voice switching simply ignore the extra fields.
    enable_character_voices: bool = True
    narrator_voice: Optional[str] = None
    character_voice: Optional[str] = None

    def __post_init__(self) -> None:
        if self.output_dir is not None and not isinstance(self.output_dir, Path):
            self.output_dir = Path(self.output_dir)
        if self.model_path is not None and not isinstance(self.model_path, Path):
            self.model_path = Path(self.model_path)
        if self.cache_dir is not None and not isinstance(self.cache_dir, Path):
            self.cache_dir = Path(self.cache_dir)

    def as_dict(self) -> Dict[str, object]:
        """Return a serialisable representation useful for debugging."""
        data: Dict[str, object] = {
            "engine": self.engine,
            "job_id": self.job_id,
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
            "edge_auto_tune": self.edge_auto_tune,
            "edge_enable_parallel": self.edge_enable_parallel,
            "edge_max_concurrency": self.edge_max_concurrency,
            "prefer_monolingual_edge": self.prefer_monolingual_edge,
            "auto_prefer_piper": self.auto_prefer_piper,
            "coqui_chunk_chars": self.coqui_chunk_chars,
            "coqui_max_workers": self.coqui_max_workers,
            "coqui_safe_mode": self.coqui_safe_mode,
            "piper_max_procs": self.piper_max_procs,
            "piper_chunk_chars": self.piper_chunk_chars,
        }
        if self.extra:
            data["extra"] = dict(self.extra)
        data["speak_formatting_cues"] = self.speak_formatting_cues
        data["formatting_locale"] = self.formatting_locale
        data["verify_transcription"] = self.verify_transcription
        data["transcription_model"] = self.transcription_model
        data["validate_text"] = self.validate_text
        data["validate_audio"] = self.validate_audio
        data["strict_validate"] = self.strict_validate
        data["deep_validate"] = self.deep_validate
        data["validation_language"] = self.validation_language
        data["chapter_intro_silence_ms"] = self.chapter_intro_silence_ms
        data["chapter_outro_silence_ms"] = self.chapter_outro_silence_ms
        data["enable_character_voices"] = self.enable_character_voices
        data["narrator_voice"] = self.narrator_voice
        data["character_voice"] = self.character_voice
        return data


class VoiceConfigProvider:
    """Expose curated voices and models used by the CLI and tests."""

    def __init__(self) -> None:
        self._edge_voice_catalog: List[Dict[str, object]] = [
            {
                "id": "pt-BR-ThalitaMultilingualNeural",
                "label": "Thalita – pt-BR (multilingual)",
                "multilingual": True,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-FranciscaNeural",
                "label": "Francisca – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-AntonioNeural",
                "label": "Antonio – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-BrendaNeural",
                "label": "Brenda – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-ElzaNeural",
                "label": "Elza – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-GiovannaNeural",
                "label": "Giovanna – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-LeilaNeural",
                "label": "Leila – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-LeticiaNeural",
                "label": "Leticia – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-ManuelaNeural",
                "label": "Manuela – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-YaraNeural",
                "label": "Yara – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-DonatoNeural",
                "label": "Donato – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-FabioNeural",
                "label": "Fabio – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-HumbertoNeural",
                "label": "Humberto – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-JulioNeural",
                "label": "Julio – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-NicolauNeural",
                "label": "Nicolau – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "pt-BR-ValerioNeural",
                "label": "Valerio – pt-BR",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "en-US-JennyNeural",
                "label": "Jenny – en-US",
                "multilingual": False,
                "language": "en-US",
            },
            {
                "id": "es-ES-ElviraNeural",
                "label": "Elvira – es-ES",
                "multilingual": False,
                "language": "es-ES",
            },
            {
                "id": "it-IT-IsabellaNeural",
                "label": "Isabella – it-IT",
                "multilingual": False,
                "language": "it-IT",
            },
        ]
        self._edge_voices = {
            str(index): (entry["id"], entry["label"])
            for index, entry in enumerate(self._edge_voice_catalog, start=1)
        }
        self._edge_voice_metadata = {
            str(entry["id"]): dict(entry) for entry in self._edge_voice_catalog if entry.get("id")
        }
        self._coqui_model_catalog: List[Dict[str, object]] = [
            {
                "id": "tts_models/multilingual/multi-dataset/xtts_v2",
                "label": "XTTS v2",
                "description": "Universal multilingual model",
                "multilingual": True,
                "low_resource": False,
            },
            {
                "id": "tts_models/pt/cv/vits",
                "label": "VITS pt-BR",
                "description": "Model optimized for Portuguese",
                "multilingual": False,
                "low_resource": True,
            },
            {
                "id": "tts_models/multilingual/multi-dataset/xtts_v1",
                "label": "XTTS v1",
                "description": "Model compatible with older GPU",
                "multilingual": True,
                "low_resource": False,
            },
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
        self._coqui_default_voice = "tts_models/multilingual/multi-dataset/xtts_v2"
        self._coqui_language_map = {
            "pt": self._coqui_default_voice,
            "en": self._coqui_default_voice,
            "es": self._coqui_default_voice,
            "fr": self._coqui_default_voice,
            "de": self._coqui_default_voice,
            "it": self._coqui_default_voice,
        }
        self._piper_language_map = {
            "pt": "pt_BR",
            "en": "en_US",
        }
        self._piper_model_catalog: List[Dict[str, object]] = [
            {
                "id": "pt_BR-faber-medium.onnx",
                "label": "Faber medium (pt-BR)",
                "language": "pt-BR",
                "multilingual": False,
            },
            {
                "id": "pt_BR-edresson-low.onnx",
                "label": "Edresson low (pt-BR)",
                "language": "pt-BR",
                "multilingual": False,
            },
            {
                "id": "en_US-lessac-medium.onnx",
                "label": "Lessac medium (en-US)",
                "language": "en-US",
                "multilingual": False,
            },
        ]
        self._kokoro_voice_catalog: List[Dict[str, object]] = [
            # Curated subset — most natural per language/gender
            {
                "id": "af_heart",
                "label": "Heart – American English Female (default)",
                "multilingual": False,
                "language": "en-US",
            },
            {
                "id": "af_bella",
                "label": "Bella – American English Female",
                "multilingual": False,
                "language": "en-US",
            },
            {
                "id": "af_nova",
                "label": "Nova – American English Female",
                "multilingual": False,
                "language": "en-US",
            },
            {
                "id": "af_sarah",
                "label": "Sarah – American English Female",
                "multilingual": False,
                "language": "en-US",
            },
            {
                "id": "am_adam",
                "label": "Adam – American English Male",
                "multilingual": False,
                "language": "en-US",
            },
            {
                "id": "am_michael",
                "label": "Michael – American English Male",
                "multilingual": False,
                "language": "en-US",
            },
            {
                "id": "bf_emma",
                "label": "Emma – British English Female",
                "multilingual": False,
                "language": "en-GB",
            },
            {
                "id": "bf_alice",
                "label": "Alice – British English Female",
                "multilingual": False,
                "language": "en-GB",
            },
            {
                "id": "bm_george",
                "label": "George – British English Male",
                "multilingual": False,
                "language": "en-GB",
            },
            {
                "id": "bm_daniel",
                "label": "Daniel – British English Male",
                "multilingual": False,
                "language": "en-GB",
            },
            {
                "id": "jf_alpha",
                "label": "Alpha – Japanese Female",
                "multilingual": False,
                "language": "ja",
            },
            {
                "id": "jm_kumo",
                "label": "Kumo – Japanese Male",
                "multilingual": False,
                "language": "ja",
            },
            {
                "id": "zf_xiaobei",
                "label": "Xiaobei – Chinese Female",
                "multilingual": False,
                "language": "zh",
            },
            {
                "id": "zm_yunxi",
                "label": "Yunxi – Chinese Male",
                "multilingual": False,
                "language": "zh",
            },
        ]
        self._auto_voice_catalog = [
            {
                "id": "pt-BR-ThalitaMultilingualNeural",
                "label": "Edge Thalita (auto)",
                "multilingual": True,
                "language": "pt-BR",
            },
            {
                "id": "tts_models/pt/cv/vits",
                "label": "Coqui VITS (auto)",
                "multilingual": False,
                "language": "pt-BR",
            },
            {
                "id": "tts_models/multilingual/multi-dataset/xtts_v2",
                "label": "XTTS v2 (auto)",
                "multilingual": True,
                "language": "multi",
            },
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
            "kokoro": clone(self._kokoro_voice_catalog),
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

        discovered: Dict[str, Dict[str, object]] = {}
        for directory in dict.fromkeys(candidate_dirs):
            if not directory.exists() or not directory.is_dir():
                continue
            for path in sorted(directory.glob("*.onnx")):
                name = path.stem
                lower_name = name.lower()
                # Prefer quality-first PT-BR (Faber medium) and stable English default.
                # If Faber is unavailable, _resolve_piper_model still falls back to another PT-BR model.
                recommended = ("faber" in lower_name) or lower_name.startswith("en_us-lessac")
                discovered[name] = {
                    "name": name,
                    "path": path,
                    "recommended": recommended,
                }
        return discovered

    def get_voice(self, engine: str, primary_language: Optional[str] = None) -> Optional[str]:
        """Return a sensible default voice/model for the given engine."""

        engine = (engine or "").lower()
        language = (primary_language or "").split("-", 1)[0].lower() or None

        def _pick_multilingual(
            entries: Iterable[Dict[str, object]], lang_code: Optional[str]
        ) -> Optional[str]:
            lang_code = (lang_code or "").lower()
            multilingual = [
                e
                for e in entries
                if e.get("multilingual")
                and (
                    not lang_code
                    or str(e.get("language", "")).split("-", 1)[0].lower() == lang_code
                )
            ]
            if multilingual:
                return str(multilingual[0].get("id"))
            # fallback: first matching language
            for entry in entries:
                if (
                    lang_code
                    and str(entry.get("language", "")).split("-", 1)[0].lower() == lang_code
                ):
                    return str(entry.get("id"))
            # fallback: first entry
            return str(entries[0].get("id")) if entries else None

        if engine == "edge":
            entries = list(self._edge_voice_catalog)
            # Prefer multilingual voices for requested language; fallback to catalog first
            pick = _pick_multilingual(entries, language)
            return pick or self._edge_voices.get("1", (None,))[0]
        if engine == "coqui":
            code = (primary_language or "").split("-", 1)[0].lower()
            if code == "pt":
                return self._coqui_language_map.get("pt", self._coqui_default_voice)
            return self._coqui_default_voice
        if engine == "auto":
            # Prefer multilingual Coqui first, then multilingual Edge
            if language == "pt":
                return self._coqui_language_map.get("pt", self._edge_voices.get("1", (None,))[0])
            coqui_pick = self._coqui_default_voice
            edge_pick = _pick_multilingual(self._edge_voice_catalog, language)
            return coqui_pick or edge_pick or self._edge_voices.get("1", (None,))[0]
        if engine == "piper":
            code = (primary_language or "").split("-", 1)[0].lower()
            return self._resolve_piper_model(code)
        return None

    def get_monolingual_voice(self, primary_language: Optional[str] = None) -> Optional[str]:
        """Return a monolingual (non-multilingual) Edge voice for the given language.

        This is useful as a fallback when multilingual voices are experiencing rate limiting
        or degraded performance.
        """
        language = (primary_language or "").split("-", 1)[0].lower() or None
        if not language:
            return None

        # Find first non-multilingual voice matching the language
        for entry in self._edge_voice_catalog:
            if not entry.get("multilingual"):
                entry_lang = str(entry.get("language", "")).split("-", 1)[0].lower()
                if entry_lang == language:
                    return str(entry.get("id"))

        # Fallback to language map
        return self._edge_language_map.get(language)

    def edge_voice_is_multilingual(self, voice_id: Optional[str]) -> Optional[bool]:
        """Return True/False when we know if the Edge voice is multilingual."""
        if not voice_id:
            return None
        entry = self._edge_voice_metadata.get(str(voice_id))
        if not entry:
            return None
        return bool(entry.get("multilingual"))

    def has_piper_model(self, language: Optional[str]) -> bool:
        """Return True if a Piper model exists for the requested language."""
        code = (language or "").split("-", 1)[0].lower()
        if not code:
            return False
        model = self._resolve_piper_model(code)
        return bool(model)

    def _resolve_piper_model(self, code: str) -> Optional[str]:
        discovered = self.get_piper_models()
        if not discovered:
            return None

        prefix = self._piper_language_map.get(code, "")
        candidates = [
            entry
            for name, entry in discovered.items()
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
        primary_code = (primary_language or "").split("-", 1)[0]
        if not primary_code and fallback_voice:
            primary_code = (languages[0] if languages else "") or ""
        valid_primary = None
        for language in languages:
            code = (language or "").split("-", 1)[0]
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
                voice = (
                    self._coqui_language_map.get(code)
                    or fallback_voice
                    or self._coqui_default_voice
                )
                if voice:
                    mapping[code] = voice
            elif engine == "auto":
                voice = (
                    self._coqui_language_map.get(code)
                    or self._edge_language_map.get(code)
                    or fallback_voice
                )
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

        # Cache dir: if provided, use the given path; otherwise, use CACHE_DIR from project root
        cache_dir_value = kwargs.pop("cache_dir", None)
        cache_dir_path = Path(cache_dir_value) if cache_dir_value else CACHE_DIR

        # Output dir: if provided, use the given path; otherwise, use OUTPUT_DIR from project root
        output_dir_value = kwargs.pop("output_dir", None)
        output_dir = Path(output_dir_value) if output_dir_value else OUTPUT_DIR
        book_title = kwargs.pop("book_title", "")

        preserve_all = kwargs.pop("preserve_all_chapters", None)
        if preserve_all is None and "preserve_all" in kwargs:
            preserve_all = bool(kwargs.pop("preserve_all"))
        preserve_all = True if preserve_all is None else bool(preserve_all)

        bitrate = kwargs.pop("bitrate", "8k")  # 8k for maximum compression (audiobooks)
        sample_rate = int(kwargs.pop("sample_rate", 16_000))  # 16kHz sufficient for voice
        channels = int(kwargs.pop("channels", 1))  # Mono for audiobooks
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
        speak_formatting_cues = bool(kwargs.pop("speak_formatting_cues", True))
        formatting_locale_raw = (
            kwargs.pop("formatting_locale", None) or ConversionConfig.formatting_locale
        )
        formatting_locale = (
            str(formatting_locale_raw or ConversionConfig.formatting_locale)
            .split("-", 1)[0]
            .lower()
        )
        if formatting_locale not in {"pt", "en"}:
            formatting_locale = "en"

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
            _safe_int(
                os.getenv("EDGE_AUTO_OFFLINE_SECONDS"), ConversionConfig.edge_auto_offline_seconds
            ),
        )
        edge_auto_offline_chars = kwargs.pop(
            "edge_auto_offline_chars",
            _safe_int(
                os.getenv("EDGE_AUTO_OFFLINE_CHARS"), ConversionConfig.edge_auto_offline_chars
            ),
        )
        edge_chunk_chars = kwargs.pop(
            "edge_chunk_chars",
            _safe_int(os.getenv("EDGE_CHUNK_CHARS"), ConversionConfig.edge_chunk_chars),
        )
        edge_max_segment_seconds = kwargs.pop(
            "edge_max_segment_seconds",
            _safe_int(
                os.getenv("EDGE_MAX_SEGMENT_SECONDS"), ConversionConfig.edge_max_segment_seconds
            ),
        )
        edge_enable_parallel = kwargs.pop(
            "edge_enable_parallel",
            os.getenv("EDGE_ENABLE_PARALLEL", "true").lower() in ("true", "1", "yes"),
        )
        edge_auto_tune = kwargs.pop("edge_auto_tune", None)
        edge_max_concurrency = kwargs.pop(
            "edge_max_concurrency",
            _safe_int(os.getenv("EDGE_MAX_CONCURRENCY"), ConversionConfig.edge_max_concurrency),
        )
        coqui_chunk_chars = kwargs.pop("coqui_chunk_chars", None)
        coqui_max_workers = kwargs.pop("coqui_max_workers", None)
        coqui_safe_mode = kwargs.pop("coqui_safe_mode", None)
        piper_max_procs = kwargs.pop("piper_max_procs", None)
        piper_chunk_chars = kwargs.pop("piper_chunk_chars", None)

        # Validation settings
        verify_transcription = bool(kwargs.pop("verify_transcription", False))
        transcription_model = str(kwargs.pop("transcription_model", "small"))
        validation_language = kwargs.pop("validation_language", None)
        validate_text = bool(kwargs.pop("validate_text", True))
        validate_audio = bool(kwargs.pop("validate_audio", True))
        strict_validate = bool(kwargs.pop("strict_validate", False))
        deep_validate = bool(kwargs.pop("deep_validate", ConversionConfig.deep_validate))
        # Default flips to True in v0.3.14 — auto-detect+fix is now the
        # standard end-of-conversion step. Env override keeps the opt-out
        # path: AUTO_VALIDATE_OUTPUT=0 disables it.
        env_auto_validate = os.getenv("AUTO_VALIDATE_OUTPUT")
        if "auto_validate_output" in kwargs:
            auto_validate_output = bool(kwargs.pop("auto_validate_output"))
        elif env_auto_validate is not None:
            auto_validate_output = env_auto_validate.strip().lower() not in {
                "0",
                "false",
                "no",
                "off",
                "",
            }
        else:
            auto_validate_output = ConversionConfig.auto_validate_output
        auto_fix_output = bool(kwargs.pop("auto_fix_output", True))

        def _safe_silence(raw: object, default: int) -> int:
            try:
                value = int(raw) if raw is not None else default
            except (TypeError, ValueError):
                value = default
            return max(value, 0)

        chapter_intro_silence_ms = _safe_silence(
            kwargs.pop("chapter_intro_silence_ms", os.getenv("CHAPTER_INTRO_SILENCE_MS")),
            ConversionConfig.chapter_intro_silence_ms,
        )
        chapter_outro_silence_ms = _safe_silence(
            kwargs.pop("chapter_outro_silence_ms", os.getenv("CHAPTER_OUTRO_SILENCE_MS")),
            ConversionConfig.chapter_outro_silence_ms,
        )

        # Multi-voice narration knobs.
        enable_character_voices_raw = kwargs.pop("enable_character_voices", None)
        if enable_character_voices_raw is None:
            enable_character_voices = ConversionConfig.enable_character_voices
        else:
            enable_character_voices = bool(enable_character_voices_raw)
        narrator_voice = kwargs.pop("narrator_voice", None) or None
        character_voice = kwargs.pop("character_voice", None) or None

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
            edge_auto_tune=edge_auto_tune,
            edge_enable_parallel=edge_enable_parallel,
            edge_max_concurrency=edge_max_concurrency,
            coqui_chunk_chars=coqui_chunk_chars,
            coqui_max_workers=coqui_max_workers,
            coqui_safe_mode=coqui_safe_mode,
            piper_max_procs=piper_max_procs,
            piper_chunk_chars=piper_chunk_chars,
            speak_formatting_cues=speak_formatting_cues,
            formatting_locale=formatting_locale,
            verify_transcription=verify_transcription,
            transcription_model=transcription_model,
            validation_language=validation_language,
            validate_text=validate_text,
            validate_audio=validate_audio,
            strict_validate=strict_validate,
            deep_validate=deep_validate,
            auto_validate_output=auto_validate_output,
            auto_fix_output=auto_fix_output,
            chapter_intro_silence_ms=chapter_intro_silence_ms,
            chapter_outro_silence_ms=chapter_outro_silence_ms,
            enable_character_voices=enable_character_voices,
            narrator_voice=narrator_voice,
            character_voice=character_voice,
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
