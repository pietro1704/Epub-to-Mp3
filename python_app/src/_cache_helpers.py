# -*- coding: utf-8 -*-
"""Pure cache-helper functions extracted from ``_cache_mixin``.

Kept intentionally small and dependency-light: anything that only needs the
``ConversionConfig`` dataclass (no ``self``, no I/O) belongs here so it can be
imported and unit-tested without constructing an ``AudioConverter``. This
module establishes the composition pattern we want to grow the mixin suite
towards — helpers first, mixins as thin wrappers.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Optional

from .config import ConversionConfig
from .utils import FileManager


def hash_text(value: str) -> str:
    """Return a stable SHA-1 hash used to key pre-tts/cached text lookups."""
    return hashlib.sha1(value.encode("utf-8", errors="ignore")).hexdigest()


def compute_cache_model_bucket(config: ConversionConfig) -> Optional[str]:
    """Return a filesystem-safe bucket name identifying (engine, voice/model).

    Used by the audio/text cache so Edge, Kokoro, Piper, and Coqui outputs
    coexist under the same book cache directory without clobbering each
    other. ``None`` is returned when engine+voice produce no identifying
    signal.
    """
    engine = (getattr(config, "engine", "") or "unknown").lower()
    parts = [engine]

    voice = getattr(config, "voice", None)
    model_path = getattr(config, "model_path", None)

    if engine == "piper" and model_path:
        parts.append(Path(model_path).stem)
    elif engine == "coqui":
        if voice:
            parts.append(str(voice))
        elif model_path:
            parts.append(Path(model_path).stem)
    else:
        if voice:
            parts.append(str(voice))

    bucket_name = "__".join(part for part in parts if part)
    if not bucket_name:
        return None
    safe_bucket = FileManager.sanitize_filename(bucket_name, max_length=96)
    safe_bucket = safe_bucket.replace(" ", "_")
    return safe_bucket or None


__all__ = ["compute_cache_model_bucket", "hash_text"]
