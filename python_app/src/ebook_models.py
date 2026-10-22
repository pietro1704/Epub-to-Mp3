# -*- coding: utf-8 -*-
"""Shared identity types for legacy ebook parsing and reading."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

from .text_formatting import FormattingSegment


@dataclass(slots=True)
class Chapter:
    index: int | str
    name: str
    source_path: str
    text: str
    level: int = 1
    raw_html: Optional[str] = None
    formatting_segments: Optional[List[FormattingSegment]] = None
    speech_text: Optional[str] = None
    footnotes: Optional[List[Dict[str, str]]] = None
    _progress_index: Optional[int] = None
    _deferred_safe_pass: bool = False
    stable_id: Optional[str] = None


@dataclass(slots=True)
class TocItem:
    title: str
    href: str
    level: int
    children: List["TocItem"] = field(default_factory=list)


@dataclass(slots=True)
class Book:
    title: str
    author: str
    chapters: List[Chapter]
    toc: List[TocItem] = field(default_factory=list)
    language: Optional[str] = None  # ISO language code from EPUB metadata (e.g., 'en', 'pt')
    source_format: Optional[str] = None


@dataclass(slots=True)
class CoverImage:
    data: bytes
    media_type: str
    extension: str
