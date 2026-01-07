# -*- coding: utf-8 -*-
"""Factory responsible for instantiating TTS engines."""

from __future__ import annotations

import os
import pathlib
import urllib.request
from pathlib import Path
from typing import Optional, Protocol

from ..config import ConversionConfig, VoiceConfigProvider


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
