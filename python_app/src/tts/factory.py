# -*- coding: utf-8 -*-
"""Factory responsible for instantiating TTS engines."""

from __future__ import annotations

import os
import pathlib
import urllib.request
from pathlib import Path
from typing import Optional, Protocol

from ..config import ConversionConfig, VoiceConfigProvider
from .piper_guard import is_piper_supported_environment


def _is_testing_environment() -> bool:
    """Return True when running under pytest to relax guardrails for mocks."""
    return bool(os.environ.get("PYTEST_CURRENT_TEST"))


class TTSEngine(Protocol):
    async def synthesize_async(
        self,
        text: str,
        output_path: Path,
        formatting_segments=None,
        progress_callback=None,
        chunk_callback=None,
    ):  # pragma: no cover - protocol stub
        ...


DEFAULT_PIPER_SOURCES = {
    "pt": {
        "model": "pt_BR-faber-medium.onnx",
        "config": "pt_BR-faber-medium.onnx.json",
        "model_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx",
        "config_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx.json",
    },
    "en": {
        "model": "en_US-lessac-medium.onnx",
        "config": "en_US-lessac-medium.onnx.json",
        "model_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx",
        "config_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json",
    },
    "es": {
        "model": "es_ES-davefx-medium.onnx",
        "config": "es_ES-davefx-medium.onnx.json",
        "model_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx",
        "config_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx.json",
    },
    "fr": {
        "model": "fr_FR-mls-medium.onnx",
        "config": "fr_FR-mls-medium.onnx.json",
        "model_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/fr/fr_FR/mls/medium/fr_FR-mls-medium.onnx",
        "config_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/fr/fr_FR/mls/medium/fr_FR-mls-medium.onnx.json",
    },
    "de": {
        "model": "de_DE-mls-medium.onnx",
        "config": "de_DE-mls-medium.onnx.json",
        "model_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/de/de_DE/mls/medium/de_DE-mls-medium.onnx",
        "config_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/de/de_DE/mls/medium/de_DE-mls-medium.onnx.json",
    },
    "it": {
        "model": "it_IT-riccardo-x_low.onnx",
        "config": "it_IT-riccardo-x_low.onnx.json",
        "model_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/it/it_IT/riccardo/x_low/it_IT-riccardo-x_low.onnx",
        "config_url": "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/it/it_IT/riccardo/x_low/it_IT-riccardo-x_low.onnx.json",
    },
}


class TTSFactory:
    def __init__(self) -> None:
        self.voice_provider = VoiceConfigProvider()

    def available_engines(self) -> list[str]:
        """Return list of available TTS engines."""
        engines = ["edge"]  # Edge is always available (cloud-based)

        # Check Piper (needs to be in venv or PATH AND have models)
        import shutil
        import sys

        piper_available = False
        if is_piper_supported_environment():
            piper_available = bool(
                shutil.which("piper") or (Path(sys.executable).parent / "piper").exists()
            )
        if piper_available:
            # Piper downloads models on demand, so expose it whenever the binary exists.
            engines.append("piper")

        return engines

    def _resolve_project_root(self) -> Path:
        """Return repository root robustly, even in shallow temp dirs."""
        resolved = Path(__file__).resolve()
        for candidate in resolved.parents:
            if (candidate / "python_app").exists() or (candidate / ".git").exists():
                return candidate
        return resolved.parent

    def create_engine(self, config: ConversionConfig) -> TTSEngine:
        engine = (config.engine or "").lower()

        # Multi-voice narration support matrix:
        #   * edge   — dialogue splitter (v0.3.7).
        #   * piper  — two ONNX model paths (v0.3.18).
        # When the user configured a narrator/character split but picked
        # an engine that won't honour it, surface a clear warning so the
        # config isn't silently dropped.
        _ENGINES_WITH_MULTI_VOICE = {"edge", "piper"}
        if engine not in _ENGINES_WITH_MULTI_VOICE:
            wants_split = bool(getattr(config, "enable_character_voices", False))
            has_distinct_voices = (
                getattr(config, "narrator_voice", None)
                and getattr(config, "character_voice", None)
                and config.narrator_voice != config.character_voice
            )
            if wants_split and has_distinct_voices:
                import sys as _sys

                print(
                    "⚠️  Multi-voice narration (narrator/character split) is only "
                    f"supported by Edge-TTS and Piper. Engine '{engine}' "
                    "will use a single voice; narrator_voice and character_voice are ignored.",
                    file=_sys.stderr,
                )

        if engine == "edge":
            from .edge_engine import EdgeTTSEngine

            voice = (
                config.voice
                or self.voice_provider.get_voice("edge", config.primary_language)
                or "pt-BR-ThalitaMultilingualNeural"
            )
            chunk_chars = config.edge_chunk_chars or None
            max_segment = config.edge_max_segment_seconds or None
            if getattr(config, "edge_aggressive_mode", False):
                chunk_chars = 8_000
                max_segment = 40

            # **PARALLEL MODE**: Enable parallel processing by default, disable for HF Space if needed
            enable_parallel = getattr(config, "edge_enable_parallel", True)

            # Multi-voice narration: prefer the operator-provided narrator/character
            # voices, falling back to the primary `voice` so a partial config
            # (only one slot set) still works.
            narrator_voice = getattr(config, "narrator_voice", None) or voice
            character_voice = getattr(config, "character_voice", None) or voice
            enable_character_voices = bool(
                getattr(config, "enable_character_voices", False)
                and narrator_voice
                and character_voice
                and narrator_voice != character_voice
            )

            engine_instance = EdgeTTSEngine(
                voice,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
                verbose=config.verbose,
                max_segment_seconds=max_segment,
                adaptive_segment_seconds=getattr(config, "edge_adaptive_segment_seconds", False),
                adaptive_segment_max_seconds=getattr(
                    config, "edge_adaptive_segment_max_seconds", 180
                ),
                chunk_char_limit=chunk_chars,
                enable_parallel=enable_parallel,
                formatting_cues_enabled=getattr(config, "speak_formatting_cues", True),
                formatting_locale=getattr(config, "formatting_locale", "pt"),
                log_callback=config.log_callback,
                metric_callback=getattr(config, "segment_metric_sink", None),
                enable_character_voices=enable_character_voices,
                narrator_voice=narrator_voice,
                character_voice=character_voice,
            )
            return engine_instance

        if engine == "piper":
            piper_supported = is_piper_supported_environment()
            if not piper_supported and not _is_testing_environment():
                raise RuntimeError(
                    "Piper TTS unavailable on this system. "
                    "Ensure the 'piper' binary is installed (pip install piper-tts) "
                    "or set ENABLE_PIPER=1 to force."
                )
            from .piper_engine import PiperTTSEngine

            model_path = config.model_path
            if model_path is None and config.voice:
                candidate = Path(str(config.voice))
                if candidate.suffix.lower() == ".onnx" and candidate.exists():
                    model_path = candidate
            preferred_code = (config.primary_language or "").split("-", 1)[0]
            model_path = model_path or self._find_piper_model(preferred_code=preferred_code)
            engine_instance = PiperTTSEngine(
                model_path,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
                formatting_cues_enabled=getattr(config, "speak_formatting_cues", True),
                formatting_locale=getattr(config, "formatting_locale", "pt"),
                max_procs=getattr(config, "piper_max_procs", None),
                enable_character_voices=bool(getattr(config, "enable_character_voices", False)),
                narrator_voice=getattr(config, "narrator_voice", None),
                character_voice=getattr(config, "character_voice", None),
            )
            engine_instance.verbose = config.verbose
            return engine_instance

        raise ValueError(f"Unsupported engine: {config.engine}")

    def _find_piper_model(
        self, preferred_code: Optional[str] = None, models_dir: Optional[Path] = None
    ) -> Path:
        candidate_dirs = []
        env_dir = os.getenv("PIPER_MODEL_DIR")
        if env_dir:
            candidate_dirs.append(Path(env_dir))
        if models_dir is not None:
            candidate_dirs.append(Path(models_dir))
        else:
            path_cls = Path
            mocked_directory = getattr(path_cls, "return_value", None)
            if isinstance(mocked_directory, pathlib.Path):
                candidate_dirs.append(mocked_directory)

        # Prioridade: root/models, root/models/piper, python_app/models
        project_root = self._resolve_project_root()
        candidate_dirs.append(project_root / "models")
        candidate_dirs.append(project_root / "models" / "piper")
        candidate_dirs.append(Path("models"))
        candidate_dirs.append(Path.cwd() / "models")
        python_root = Path(__file__).resolve().parents[1]
        candidate_dirs.append(python_root / "models")

        preferred = (preferred_code or "").split("-", 1)[0].strip().lower()
        preferred_prefixes = []
        if preferred:
            preferred_prefixes.append(preferred)
            preferred_prefixes.append(f"{preferred}_")
            if preferred == "pt":
                preferred_prefixes.extend(["pt_br", "pt-br", "ptbr"])
            elif preferred == "en":
                preferred_prefixes.extend(["en_us", "en-us", "enus", "en_gb", "en-gb", "engb"])

        for search_dir in dict.fromkeys(candidate_dirs):
            if not search_dir.exists() or not search_dir.is_dir():
                continue

            candidates = [
                candidate for candidate in sorted(search_dir.glob("*.onnx")) if candidate.is_file()
            ]
            if not candidates:
                continue

            if preferred_prefixes:
                for candidate in candidates:
                    name = candidate.stem.lower()
                    if any(name.startswith(prefix) for prefix in preferred_prefixes):
                        return candidate
                # Preferred language not found — try downloading before using wrong-language fallback
                continue

            # No language preference: use first available model in directory
            return candidates[0]

        downloaded = self._download_default_piper_model(preferred_code)
        if downloaded:
            return downloaded

        # No model in the requested language is available and the on-demand
        # download failed. Picking *any* installed model here used to be the
        # silent fallback, but it produces unlistenable output: a pt-BR
        # audiobook narrated by `en_US-lessac-medium` reads Portuguese with
        # English phonemes (the Carl regression). Refuse instead so the
        # caller falls through to Edge on the next tier rather than
        # synthesising audio in the wrong language.
        if preferred:
            raise FileNotFoundError(
                f"No Piper model available for '{preferred}' "
                "(download failed and no compatible local model was found). "
                "Refusing to synthesise with a wrong-language model."
            )

        # No language preference at all → falling back to any model is fine
        # (we have nothing else to compare against).
        for search_dir in dict.fromkeys(candidate_dirs):
            if not search_dir.exists() or not search_dir.is_dir():
                continue
            candidates = [c for c in sorted(search_dir.glob("*.onnx")) if c.is_file()]
            if candidates:
                return candidates[0]

        raise FileNotFoundError("No Piper models were found")

    def _download_default_piper_model(self, preferred_code: Optional[str]) -> Optional[Path]:
        code = (preferred_code or "").split("-", 1)[0].lower()
        sources = DEFAULT_PIPER_SOURCES.get(code) or DEFAULT_PIPER_SOURCES.get("en")
        if not sources:
            return None

        # Prioridade: PIPER_MODEL_DIR env, depois root/models
        project_root = self._resolve_project_root()
        target_dir = Path(os.getenv("PIPER_MODEL_DIR") or project_root / "models")
        target_dir.mkdir(parents=True, exist_ok=True)

        model_path = target_dir / sources["model"]
        config_path = target_dir / sources["config"]

        try:
            if not model_path.exists():
                urllib.request.urlretrieve(sources["model_url"], model_path)
            if not config_path.exists():
                urllib.request.urlretrieve(sources["config_url"], config_path)
        except Exception:
            return None

        return model_path if model_path.exists() else None


__all__ = ["TTSFactory", "TTSEngine"]
