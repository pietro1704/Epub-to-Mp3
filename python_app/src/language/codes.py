# -*- coding: utf-8 -*-
"""Language code helpers."""

from __future__ import annotations

from functools import lru_cache

LANGUAGE_TO_BCP47 = {
    "pt": "pt-BR",
    "en": "en-US",
    "es": "es-ES",
    "fr": "fr-FR",
    "de": "de-DE",
    "it": "it-IT",
    "ru": "ru-RU",
    "ja": "ja-JP",
    "zh": "zh-CN",
    "ko": "ko-KR",
}


@lru_cache(maxsize=None)
def ensure_bcp47(language: str | None) -> str:
    if not language:
        return ""
    language = language.strip().lower()
    if not language:
        return ""
    if "-" in language:
        return language
    return LANGUAGE_TO_BCP47.get(language, language)


__all__ = ["ensure_bcp47"]
