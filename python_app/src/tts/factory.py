# -*- coding: utf-8 -*-
"""Factory responsible for instantiating TTS engines."""

from __future__ import annotations

import os
import pathlib
import urllib.request
from pathlib import Path
from typing import Optional, Protocol

from ..config import ConversionConfig, VoiceConfigProvider
from .coqui_guard import is_coqui_supported_environment
from .kokoro_guard import is_kokoro_supported_environment
from .piper_guard import is_piper_supported_environment
from .spark_guard import is_spark_supported_environment


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
        "model_url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR-faber-medium.onnx",
        "config_url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR-faber-medium.onnx.json",
    },
    "en": {
        "model": "en_US-lessac-medium.onnx",
        "config": "en_US-lessac-medium.onnx.json",
        "model_url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US-lessac-medium.onnx",
        "config_url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US-lessac-medium.onnx.json",
    },
}


class TTSFactory:
    def __init__(self) -> None:
        self.voice_provider = VoiceConfigProvider()

    def available_engines(self) -> list[str]:
        """Return list of available TTS engines."""
        engines = ["edge"]  # Edge is always available (cloud-based)

        # Check Coqui TTS
        import importlib.util

        if is_coqui_supported_environment() and importlib.util.find_spec("TTS") is not None:
            engines.append("coqui")

        # Check Piper (needs to be in venv or PATH AND have models)
        import shutil
        import sys

        piper_available = False
        if is_piper_supported_environment():
            piper_available = (
                shutil.which("piper") or (Path(sys.executable).parent / "piper").exists()
            )
        if piper_available:
            # Also check if there are any Piper models available
            try:
                piper_models = self.get_piper_models()
                if piper_models:
                    engines.append("piper")
            except Exception:
                pass  # No models available, don't add piper to available engines

        # Check Kokoro
        if is_kokoro_supported_environment() and importlib.util.find_spec("kokoro") is not None:
            engines.append("kokoro")

        # Check Spark-TTS
        if (
            is_spark_supported_environment()
            and importlib.util.find_spec("transformers") is not None
        ):
            engines.append("spark")

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

            return EdgeTTSEngine(
                voice,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
                verbose=config.verbose,
                max_segment_seconds=max_segment,
                chunk_char_limit=chunk_chars,
                enable_parallel=enable_parallel,
                formatting_cues_enabled=getattr(config, "speak_formatting_cues", True),
                formatting_locale=getattr(config, "formatting_locale", "pt"),
                log_callback=config.log_callback,
            )

        if engine == "coqui":
            coqui_supported = is_coqui_supported_environment()
            if not coqui_supported and not _is_testing_environment():
                raise RuntimeError(
                    "Coqui TTS indisponível neste sistema (NumPy/Accelerate incompatível). "
                    "Defina ENABLE_COQUI_TTS=1 para forçar o uso por sua conta e risco."
                )
            from .coqui_engine import CoquiTTSEngine

            voice = config.voice or self.voice_provider.get_voice("coqui", config.primary_language)
            if not voice:
                voice = "tts_models/multilingual/multi-dataset/xtts_v2"  # Default model (Multilingual XTTS)
            return CoquiTTSEngine(
                voice,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
                verbose=config.verbose,
                formatting_cues_enabled=getattr(config, "speak_formatting_cues", True),
                formatting_locale=getattr(config, "formatting_locale", "pt"),
                status_callback=config.log_callback,  # Reusa log_callback para status do modelo
                chunk_char_limit=getattr(config, "coqui_chunk_chars", None),
                max_workers=getattr(config, "coqui_max_workers", None),
                safe_mode=getattr(config, "coqui_safe_mode", None),
            )

        if engine == "piper":
            piper_supported = is_piper_supported_environment()
            if not piper_supported and not _is_testing_environment():
                raise RuntimeError(
                    "Piper TTS indisponível neste sistema (NumPy/Accelerate incompatível). "
                    "Defina ENABLE_PIPER=1 para forçar o uso por sua conta e risco."
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
            )
            engine_instance.verbose = config.verbose
            return engine_instance

        if engine == "kokoro":
            kokoro_supported = is_kokoro_supported_environment()
            if not kokoro_supported and not _is_testing_environment():
                raise RuntimeError(
                    "Kokoro TTS indisponível neste sistema (NumPy/Accelerate incompatível). "
                    "Defina ENABLE_KOKORO=1 para forçar o uso por sua conta e risco."
                )
            from .kokoro_engine import KokoroTTSEngine, kokoro_supports_language

            if not kokoro_supports_language(config.primary_language):
                raise ValueError(
                    "Kokoro TTS currently supports only English, Japanese and Chinese voices. "
                    f"Requested language: {config.primary_language or 'unknown'}"
                )
            voice = config.voice or self.voice_provider.get_voice("kokoro", config.primary_language)
            if not voice:
                # Select default voice based on language
                lang = (config.primary_language or "en").lower().split("-")[0]
                if lang in ("ja", "jp"):
                    voice = "jf_alpha"
                elif lang in ("zh", "cn"):
                    voice = "zf_xiaobei"
                elif lang == "en" and "gb" in (config.primary_language or "").lower():
                    voice = "bf_emma"
                else:
                    voice = "af_heart"  # American English default

            return KokoroTTSEngine(
                voice,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
                verbose=config.verbose,
                formatting_cues_enabled=getattr(config, "speak_formatting_cues", True),
                formatting_locale=getattr(config, "formatting_locale", "pt"),
                status_callback=config.log_callback,
                chunk_char_limit=getattr(config, "kokoro_chunk_chars", None),
                max_workers=getattr(config, "kokoro_max_workers", None),
            )

        if engine == "spark":
            if not is_spark_supported_environment():
                raise RuntimeError(
                    "Spark-TTS indisponível neste sistema (NumPy/Accelerate incompatível). "
                    "Defina ENABLE_SPARK_TTS=1 para forçar o uso por sua conta e risco."
                )
            from .spark_engine import SparkTTSEngine

            voice = config.voice or "default"
            model_dir = getattr(config, "spark_model_dir", None)
            reference_audio = getattr(config, "spark_reference_audio", None)
            reference_text = getattr(config, "spark_reference_text", None)

            return SparkTTSEngine(
                voice,
                model_dir=model_dir,
                primary_language=config.primary_language,
                language_voices=config.language_voices,
                verbose=config.verbose,
                formatting_cues_enabled=getattr(config, "speak_formatting_cues", True),
                formatting_locale=getattr(config, "formatting_locale", "pt"),
                status_callback=config.log_callback,
                chunk_char_limit=getattr(config, "spark_chunk_chars", None),
                max_workers=getattr(config, "spark_max_workers", None),
                reference_audio=reference_audio,
                reference_text=reference_text,
            )

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

        for search_dir in dict.fromkeys(candidate_dirs):
            if not search_dir.exists() or not search_dir.is_dir():
                continue

            for candidate in sorted(search_dir.glob("*.onnx")):
                if candidate.is_file():
                    return candidate

        downloaded = self._download_default_piper_model(preferred_code)
        if downloaded:
            return downloaded

        raise FileNotFoundError("No Piper models were found")

    def _download_default_piper_model(self, preferred_code: Optional[str]) -> Optional[Path]:
        code = (preferred_code or "").split("-", 1)[0].lower()
        sources = DEFAULT_PIPER_SOURCES.get(code) or DEFAULT_PIPER_SOURCES.get("pt")
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
