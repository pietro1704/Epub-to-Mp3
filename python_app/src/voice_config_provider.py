# -*- coding: utf-8 -*-
"""Curated voice selection and installed Piper model discovery."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Dict, Iterable, List, Optional


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
        self._edge_language_map = {
            "pt": "pt-BR-ThalitaMultilingualNeural",
            "en": "en-US-JennyNeural",
            "es": "es-ES-ElviraNeural",
            "fr": "fr-FR-DeniseNeural",
            "de": "de-DE-ConradNeural",
            "it": "it-IT-IsabellaNeural",
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
        self._auto_voice_catalog = [
            {
                "id": "pt-BR-ThalitaMultilingualNeural",
                "label": "Edge Thalita (auto)",
                "multilingual": True,
                "language": "pt-BR",
            },
        ]

    @property
    def edge_voices(self) -> Dict[str, tuple[str, str]]:
        return dict(self._edge_voices)

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
        if engine == "auto":
            edge_pick = _pick_multilingual(self._edge_voice_catalog, language)
            return edge_pick or self._edge_voices.get("1", (None,))[0]
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
            elif engine == "auto":
                voice = self._edge_language_map.get(code) or fallback_voice
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
