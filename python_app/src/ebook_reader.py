# -*- coding: utf-8 -*-
"""Lightweight EPUB/PDF reader used across the simplified test-suite."""

from __future__ import annotations

import base64
import html
import json
import os
import posixpath
import re
import threading
import time
from collections import OrderedDict

try:
    import zipfile
except ImportError:
    zipfile = None  # type: ignore[assignment]
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

try:
    import hashlib
except ImportError:
    hashlib = None  # type: ignore[assignment]

try:
    import mimetypes
except ImportError:
    mimetypes = None  # type: ignore[assignment]

try:
    from urllib.parse import unquote
except ImportError:

    def unquote(s: str, encoding: str = "utf-8", errors: str = "replace") -> str:
        parts = s.split("%")
        if len(parts) == 1:
            return s
        result = [parts[0]]
        for item in parts[1:]:
            try:
                result.append(bytes.fromhex(item[:2]).decode(encoding, errors) + item[2:])
            except (ValueError, UnicodeDecodeError):
                result.append("%" + item)
        return "".join(result)


from xml.etree import ElementTree as ET

from .text_formatting import FormattingSegment, TextFormattingProcessor

try:  # pragma: no cover - exercised indirectly in tests
    import pypdf  # type: ignore

    PDF_AVAILABLE = True
except ImportError:  # pragma: no cover - when pypdf is missing
    pypdf = None
    PDF_AVAILABLE = False

# Public regular expressions expected by the tests ---------------------------------
TAG_RE = re.compile(r"<[^>]+>")
WHITESPACE_RE = re.compile(r"[ \t\f\v]+")
NBSP_RE = re.compile(r"(?:&nbsp;|\u00A0)", re.I)
PARA_BLOCK_RE = re.compile(
    r"</?(p|div|br|li|tr|td|th|blockquote|section|article|hr|h[1-6])[^>]*>", re.I
)
ARTIFACT_RE = re.compile(r"\b(?:[\w\-/]+\.(?:xhtml|html|opf|ncx|css)|\d+_[\w-]+)\b", re.I)
H_TAG = re.compile(r"<h([1-6])[^>]*>(.*?)</h\1>", re.I | re.DOTALL)
PAGE_BREAK_RE = re.compile(
    r"page-break-before\s*:\s*always|page-break-after\s*:\s*always|break-before\s*:\s*page|break-after\s*:\s*page",
    re.I,
)

# CSS class names (matched as substrings) for section-number paragraphs that
# open a new subchapter block.  The split point is the number element; the
# title is taken from the immediately following SUBCHAPTER_TITLE_CLASS element.
#   class_s3P-0 → first section in a chapter  (e.g. "1" in IT ch.11)
#   class_s42-0 → subsequent sections          (e.g. "2", "3" … in IT ch.11)
# Add more names here for other conversion tool artefacts.
SUBCHAPTER_NUMBER_CLASSES: frozenset = frozenset({"class_s3P-0", "class_s42-0"})

# CSS class name of the title paragraph that immediately follows a section-
# number paragraph.  Its text content becomes the sub-chapter name
# (e.g. "Ben Hanscom faz uma retirada").
SUBCHAPTER_TITLE_CLASS: str = "class_sG5"


# Plain-text character threshold above which a chapter is split at paragraph
# boundaries to prevent Edge-TTS timeout on very large chapters.
# Computed at import time from Edge env vars so the threshold scales with
# the runtime concurrency profile (e.g. HF vs local).
# Formula: max(EDGE_CHUNK_CHARS × EDGE_MAX_CONCURRENCY × 2, 20_000)
#   local  (concurrency=12): 12_000 × 12 × 2 = 288_000  → rarely splits
#   HF     (concurrency=1 ): 12_000 ×  1 × 2 =  24_000  → splits large chapters
def _default_split_chars() -> int:
    import os

    chunk = max(int(os.getenv("EDGE_CHUNK_CHARS", 12_000)), 1_000)
    concurrency = max(int(os.getenv("EDGE_MAX_CONCURRENCY", 12)), 1)
    return max(chunk * concurrency * 2, 20_000)


SUBCHAPTER_MAX_CHARS: int = _default_split_chars()

XML_NS = {
    "ocf": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
}


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


@dataclass(slots=True)
class CoverImage:
    data: bytes
    media_type: str
    extension: str


class TextProcessor:
    """Utility helpers for dealing with HTML text inside EPUB files."""

    @staticmethod
    def strip_html_tags(content: Optional[str]) -> str:
        if not content:
            return ""

        class _TagStripper(HTMLParser):
            def __init__(self) -> None:
                super().__init__(convert_charrefs=False)
                self.parts: list[str] = []

            def handle_data(self, data: str) -> None:
                self.parts.append(data)

            def handle_entityref(self, name: str) -> None:
                self.parts.append(f"&{name};")

            def handle_charref(self, name: str) -> None:
                self.parts.append(f"&#{name};")

        parser = _TagStripper()
        parser.feed(str(content))
        parser.close()
        return "".join(parser.parts)

    @staticmethod
    def strip_ignored_html_blocks(content: Optional[str]) -> str:
        if not content:
            return ""

        class _IgnoredBlockStripper(HTMLParser):
            def __init__(self) -> None:
                super().__init__(convert_charrefs=False)
                self._ignored_stack: list[str] = []
                self.parts: list[str] = []

            def handle_starttag(self, tag: str, attrs: list[tuple[str, Optional[str]]]) -> None:
                if tag in {"style", "script", "head", "title"}:
                    self._ignored_stack.append(tag)
                    return
                if self._ignored_stack:
                    return
                attrs_text = "".join(
                    f' {name}="{html.escape(value, quote=True)}"'
                    if value is not None
                    else f" {name}"
                    for name, value in attrs
                )
                self.parts.append(f"<{tag}{attrs_text}>")

            def handle_startendtag(self, tag: str, attrs: list[tuple[str, Optional[str]]]) -> None:
                if tag in {"style", "script", "head", "title"} or self._ignored_stack:
                    return
                attrs_text = "".join(
                    f' {name}="{html.escape(value, quote=True)}"'
                    if value is not None
                    else f" {name}"
                    for name, value in attrs
                )
                self.parts.append(f"<{tag}{attrs_text}/>")

            def handle_endtag(self, tag: str) -> None:
                if self._ignored_stack:
                    if tag == self._ignored_stack[-1]:
                        self._ignored_stack.pop()
                    return
                self.parts.append(f"</{tag}>")

            def handle_data(self, data: str) -> None:
                if not self._ignored_stack:
                    self.parts.append(data)

            def handle_entityref(self, name: str) -> None:
                if not self._ignored_stack:
                    self.parts.append(f"&{name};")

            def handle_charref(self, name: str) -> None:
                if not self._ignored_stack:
                    self.parts.append(f"&#{name};")

            def handle_comment(self, data: str) -> None:
                if not self._ignored_stack:
                    self.parts.append(f"<!--{data}-->")

            def handle_decl(self, decl: str) -> None:
                if not self._ignored_stack:
                    self.parts.append(f"<!{decl}>")

        parser = _IgnoredBlockStripper()
        parser.feed(str(content))
        parser.close()
        return "".join(parser.parts)

    @staticmethod
    def clean_chapter_title(title: str) -> str:
        """Remove common EPUB export prefixes like 'part0001' from chapter titles."""
        if not title:
            return title
        cleaned = TextProcessor.normalise_whitespace(title)
        cleaned = re.sub(r"^(?:part\d{3,})(?:\s*[-–:]\s*|\s+)", "", cleaned, flags=re.IGNORECASE)
        cleaned = cleaned.strip()
        return cleaned or title.strip()

    @staticmethod
    def html_to_plain_text_with_formatting(
        content: Optional[str],
    ) -> Tuple[str, List[FormattingSegment]]:
        """Convert HTML to plain text while preserving formatting information"""
        if not content:
            return "", []

        # Initialize formatting processor
        formatter = TextFormattingProcessor()
        cleaned_content = TextProcessor.strip_ignored_html_blocks(content)

        # Extract formatting and convert to internal markers
        text_with_markers = formatter.extract_formatting(cleaned_content)

        # Apply standard text processing
        text = str(text_with_markers)
        text = NBSP_RE.sub(" ", text)
        text = ARTIFACT_RE.sub(" ", text)
        text = text.replace("\r", "\n")
        # HTML treats raw newlines inside elements as whitespace. Collapse them
        # before block-element processing so only actual block boundaries (<p>,
        # <div>, <br>, etc.) become newlines — not source-level line wraps.
        text = re.sub(r"\n+", " ", text)
        text = PARA_BLOCK_RE.sub("\n", text)

        # Clean remaining HTML tags but preserve formatting markers
        text = re.sub(
            r"<(?!/?fmt)[^>]+>", "", text
        )  # Remove HTML tags but keep [[fmt:...]] markers
        text = WHITESPACE_RE.sub(" ", text)
        text = re.sub(r"\n{3,}", "\n\n", text)

        lines = [line.strip() for line in text.split("\n")]
        lines = [line for line in lines if line]
        clean_text = "\n".join(lines)

        # Parse the text with formatting markers into segments
        formatting_segments = formatter.parse_formatted_text(clean_text)

        # Render inline emphasis markers back into the text
        formatted_text = formatter.apply_inline_formatting(clean_text)
        formatted_text = re.sub(r"[ \t]{2,}", " ", formatted_text)
        formatted_text = re.sub(r"\s*\n\s*", "\n", formatted_text)
        formatted_text = formatted_text.strip()

        return formatted_text, formatting_segments

    @staticmethod
    def html_to_plain_text(content: Optional[str]) -> str:
        if not content:
            return ""

        text = TextProcessor.strip_ignored_html_blocks(str(content))

        # Preserve dialog structure - add extra newline before dialog markers
        text = re.sub(r"([.!?])\s*([—–-]\s*)", r"\1\n\2", text)

        # Convert common entities and special chars
        text = NBSP_RE.sub(" ", text)
        text = text.replace("&mdash;", "—")
        text = text.replace("&ndash;", "–")
        text = text.replace("&ldquo;", '"')
        text = text.replace("&rdquo;", '"')
        text = text.replace("&lsquo;", "'")
        text = text.replace("&rsquo;", "'")
        text = text.replace("&hellip;", "…")

        # Clean artifacts but preserve important separators
        text = ARTIFACT_RE.sub(" ", text)
        text = text.replace("\r", "\n")

        # Convert block-level tags to newlines (preserve paragraph structure)
        text = PARA_BLOCK_RE.sub("\n", text)

        # Remove remaining HTML tags
        text = TextProcessor.strip_html_tags(text)

        # Normalize whitespace within lines but preserve paragraph breaks
        text = WHITESPACE_RE.sub(" ", text)

        # Preserve double newlines (paragraph breaks) but remove excessive ones
        text = re.sub(r"\n{4,}", "\n\n\n", text)  # Max 3 newlines for section breaks

        # Process lines: strip but preserve empty lines for paragraph breaks
        lines = []
        for line in text.split("\n"):
            stripped = line.strip()
            if stripped:
                lines.append(stripped)
            elif lines and lines[-1] != "":  # Add single empty line for paragraph break
                lines.append("")

        # Remove duplicate empty lines
        result_lines = []
        prev_empty = False
        for line in lines:
            if line == "":
                if not prev_empty:
                    result_lines.append(line)
                prev_empty = True
            else:
                result_lines.append(line)
                prev_empty = False

        # Join and strip trailing newlines
        result = "\n".join(result_lines)
        return result.rstrip("\n")

    # Per-process cache for ``inject_footnotes`` results. Keyed on a sha1
    # of the raw markup. Bounded so pathological corpora don't grow it
    # unboundedly. Skipped when ``external_file_resolver`` is set: an
    # external resolver can produce different outputs across runs (it
    # walks the zip), so caching by markup alone would be unsound.
    _FOOTNOTE_CACHE_LIMIT = 256
    _footnote_cache: "Dict[str, Tuple[str, List[Dict[str, str]]]]" = {}
    _footnote_cache_lock = threading.Lock()

    @classmethod
    def clear_footnote_cache(cls) -> None:
        """Drop the per-process inject_footnotes memo. Mirrors
        ``LanguageDetector.clear_cache`` for parity — useful between CI
        runs and for test hygiene."""
        with cls._footnote_cache_lock:
            cls._footnote_cache.clear()

    @staticmethod
    def inject_footnotes(
        markup: Optional[str],
        mode: str = "inline",
        context_words: int = 8,
        external_file_resolver=None,
    ) -> tuple[str, List[Dict[str, str]]]:
        if not markup:
            return "", []

        cache_key: Optional[str] = None
        if external_file_resolver is None:
            # Hash on the markup. SHA-1 over UTF-8 is ~200MB/s — cheap
            # compared to the BS4 walk we'd otherwise repeat.
            try:
                # blake2b is ~30% faster than sha1 on long XHTML payloads
                # and we only need a stable in-memory cache key (no
                # cryptographic property required).
                cache_key = (
                    hashlib.blake2b(
                        str(markup).encode("utf-8", errors="ignore"), digest_size=20
                    ).hexdigest()
                    if hashlib is not None
                    else None
                )
            except Exception:
                cache_key = None
            if cache_key is not None:
                with TextProcessor._footnote_cache_lock:
                    hit = TextProcessor._footnote_cache.get(cache_key)
                if hit is not None:
                    # Defensive copy of the footnote list so callers can
                    # mutate it without poisoning the cache.
                    return hit[0], [dict(fn) for fn in hit[1]]

        try:
            from bs4 import BeautifulSoup  # type: ignore
        except ImportError:  # pragma: no cover - optional dependency
            BeautifulSoup = None

        if BeautifulSoup is not None:
            processed_markup, footnotes = TextProcessor._collect_footnotes_bs4(
                str(markup), BeautifulSoup, external_file_resolver
            )
        else:
            processed_markup, footnotes = TextProcessor._collect_footnotes_fallback(str(markup))

        if cache_key is not None:
            with TextProcessor._footnote_cache_lock:
                if len(TextProcessor._footnote_cache) >= TextProcessor._FOOTNOTE_CACHE_LIMIT:
                    drop = max(1, TextProcessor._FOOTNOTE_CACHE_LIMIT // 10)
                    for old in list(TextProcessor._footnote_cache.keys())[:drop]:
                        TextProcessor._footnote_cache.pop(old, None)
                TextProcessor._footnote_cache[cache_key] = (
                    processed_markup,
                    [dict(fn) for fn in footnotes],
                )

        return processed_markup, footnotes

    @staticmethod
    def _collect_footnotes_bs4(
        markup: str, BeautifulSoup, external_file_resolver=None
    ) -> Tuple[str, List[Dict[str, str]]]:
        soup = BeautifulSoup(markup, "html.parser")
        if soup is None:
            return markup, []

        footnotes: List[Dict[str, str]] = []
        note_numbers: Dict[str, str] = {}
        processed_targets: List[str] = []
        external_footnote_cache: Dict[str, any] = {}

        def normalise_fragment(href: str) -> str:
            if not href:
                return ""
            fragment = href.split("#", 1)[-1] if "#" in href else ""
            return fragment.strip()

        def looks_like_noteref(anchor, target_text: str, note_node=None) -> bool:
            if anchor is None or not hasattr(anchor, "get"):
                return False
            anchor_text = (anchor.get_text(" ", strip=True) or "").strip()
            role = (safe_get(anchor, "role", "") or "").lower()
            epub_type = ""
            for attr_name in ("epub:type", "epub:type", "epub-type", "type"):
                value = safe_get(anchor, attr_name)
                if value:
                    epub_type = str(value).lower()
                    break
            classes = normalise_classes(safe_get(anchor, "class", []))
            href_value = (
                safe_get(anchor, "href", "") or safe_get(anchor, "xlink:href", "") or ""
            ).lower()
            anchor_id = (safe_get(anchor, "id", "") or "").lower()
            fragment_value = href_value.split("#", 1)[-1] if "#" in href_value else ""
            parent_name = (getattr(getattr(anchor, "parent", None), "name", "") or "").lower()
            is_superscript = parent_name == "sup"

            target_tag = (getattr(note_node, "name", "") or "").lower() if note_node else ""
            target_role = (safe_get(note_node, "role", "") or "").lower() if note_node else ""
            target_epub_type = ""
            if note_node is not None:
                for attr_name in ("epub:type", "epub-type", "type"):
                    value = safe_get(note_node, attr_name)
                    if value:
                        target_epub_type = str(value).lower()
                        break
            target_classes = (
                normalise_classes(safe_get(note_node, "class", [])) if note_node else []
            )

            explicit_href_hint = bool(
                re.search(r"(?:^|[#/_-])(foot|fn|note|rodape|rodapé)\w*", href_value)
            )
            explicit_target_hint = bool(
                target_tag in {"aside", "li"}
                or "footnote" in target_role
                or "footnote" in target_epub_type
                or any("footnote" in cls or "nota" in cls for cls in target_classes)
                or re.search(r"(foot|fn|note|rodape|rodapé)\w*", fragment_value)
            )

            if (
                "noteref" in classes
                or "footnote" in classes
                or role == "doc-noteref"
                or epub_type == "noteref"
                or "footnote" in href_value
                or "footnote" in anchor_id
                or "idfootnotelink" in classes
            ):
                return True
            if explicit_target_hint or explicit_href_hint:
                return True
            if anchor_text:
                digits_only = "".join(ch for ch in anchor_text if ch.isdigit())
                if digits_only.isdigit():
                    # Do not treat any numeric internal link as footnote; this
                    # can remove legitimate section numbers (e.g. chapter starts with "1").
                    return is_superscript
            if target_text and any(
                token in target_text.lower() for token in ("nota", "footnote", "rodapé", "rodape")
            ):
                return True
            return False

        def safe_get(tag, key, default=None):
            """Safely access BeautifulSoup tag attributes even when attrs is missing."""
            if tag is None or not hasattr(tag, "attrs"):
                return default
            attrs = getattr(tag, "attrs", None)
            if not isinstance(attrs, dict):
                return default
            return attrs.get(key, default)

        def normalise_classes(value) -> List[str]:
            if not value:
                return []
            if isinstance(value, (list, tuple, set)):
                return [str(item).lower() for item in value]
            return [str(value).lower()]

        def extract_note_text(node) -> str:
            if node is None:
                return ""
            # If node is an anchor that is empty or contains only a numeric label
            # (i.e. it's a backlink target, not the actual footnote container),
            # use the parent element which holds the full note content.
            if node.name == "a" and node.parent:
                anchor_text = node.get_text(strip=True)
                is_numeric_label = anchor_text.isdigit() or (
                    anchor_text.startswith("[")
                    and anchor_text.endswith("]")
                    and anchor_text[1:-1].isdigit()
                )
                if not anchor_text or is_numeric_label:
                    node = node.parent
            for backlink in node.find_all("a"):
                if backlink is None or not hasattr(backlink, "get"):
                    continue
                href = safe_get(backlink, "href", "")
                if href.startswith("#"):
                    backlink.decompose()
            raw = node.get_text(" ", strip=True)
            return TextProcessor.normalise_whitespace(raw)

        def strip_leading_label(text: str, label: str) -> str:
            if not text:
                return ""
            cleaned = text.strip()
            label = (label or "").strip()

            # Extract only digits from label for comparison
            label_digits = "".join(ch for ch in label if ch.isdigit())

            if label_digits:
                # Try to remove various forms of number/label at the beginning
                candidates = [
                    label,  # Full label (e.g.: "[1]")
                    f"[{label}]",
                    f"({label})",
                    f"{label}.",
                    f"{label}:",
                    f"{label}-",
                    f"[{label_digits}]",
                    f"({label_digits})",
                    f"{label_digits}.",
                    f"{label_digits}:",
                    f"{label_digits}-",
                    label_digits,  # Just the number (e.g.: "1")
                ]

                lowered = cleaned.lower()
                for candidate in candidates:
                    candidate_clean = candidate.strip()
                    if not candidate_clean:
                        continue
                    if lowered.startswith(candidate_clean.lower()):
                        cleaned = cleaned[len(candidate_clean) :].lstrip(" .:-)–—")
                        break

            return cleaned.strip()

        # Maps fragment id → the soup node to decompose during cleanup.
        # When the target node is a backlink anchor, its parent container is used
        # so that the full footnote block is removed (not just the anchor).
        cleanup_targets: Dict[str, any] = {}

        for anchor in list(soup.find_all("a")):
            if anchor is None or not hasattr(anchor, "get"):
                continue
            href = safe_get(anchor, "href", "") or safe_get(anchor, "xlink:href", "")
            fragment = normalise_fragment(href)
            if not fragment:
                continue

            # Try to find note in current document
            note_node = soup.find(id=fragment)

            # If not found and href points to external file, try to load it
            if not note_node and external_file_resolver and "#" in href:
                external_file = href.split("#")[0]
                if external_file and external_file not in external_footnote_cache:
                    try:
                        external_html = external_file_resolver(external_file)
                        if external_html:
                            external_footnote_cache[external_file] = BeautifulSoup(
                                external_html, "html.parser"
                            )
                    except Exception:
                        external_footnote_cache[external_file] = None

                external_soup = external_footnote_cache.get(external_file)
                if external_soup:
                    note_node = external_soup.find(id=fragment)

            # Determine the cleanup target before extract_note_text may decompose
            # the anchor.  When the target is a backlink anchor (contains only a
            # numeric label or is empty), the actual note content lives in its
            # parent container — remove that parent during cleanup so no duplicate
            # text remains in the document.
            if note_node is not None and note_node.name == "a":
                anchor_text = note_node.get_text(strip=True)
                is_numeric_label = anchor_text.isdigit() or (
                    anchor_text.startswith("[")
                    and anchor_text.endswith("]")
                    and anchor_text[1:-1].isdigit()
                )
                if not anchor_text or is_numeric_label:
                    cleanup_targets[fragment] = note_node.parent or note_node
                else:
                    cleanup_targets[fragment] = note_node
            elif note_node is not None:
                cleanup_targets[fragment] = note_node

            note_text = extract_note_text(note_node)
            if not note_text:
                continue
            if not looks_like_noteref(anchor, note_text, note_node):
                continue

            label = anchor.get_text(" ", strip=True)
            number_hint = "".join(ch for ch in label if ch.isdigit())
            if fragment in note_numbers:
                note_number = note_numbers[fragment]
            else:
                if number_hint.isdigit():
                    note_number = number_hint
                else:
                    note_number = str(len(note_numbers) + 1)
                note_numbers[fragment] = note_number
            cleaned_text = strip_leading_label(note_text, label)
            if not cleaned_text:
                cleaned_text = note_text.strip()

            marker_token = f"[[FOOTNOTE_{len(footnotes) + 1}]]"
            footnotes.append(
                {
                    "marker": marker_token,
                    "number": note_number,
                    "text": cleaned_text,
                    "original_text": TextProcessor.normalise_whitespace(note_text),
                }
            )

            anchor.replace_with(marker_token)
            parent = anchor.parent
            if parent and parent.name == "sup" and not parent.get_text(strip=True):
                parent.decompose()

            processed_targets.append(fragment)

        for fragment in set(processed_targets):
            node = cleanup_targets.get(fragment) or soup.find(id=fragment)
            if node is not None:
                try:
                    node.decompose()
                except Exception:
                    pass

        return str(soup), footnotes

    @staticmethod
    def _collect_footnotes_fallback(markup: str) -> Tuple[str, List[Dict[str, str]]]:
        anchor_pattern = re.compile(
            r'(<sup[^>]*>\s*)?<a[^>]+href=["\"][^"#\']*#(?P<fragment>[^"\']+)["\"][^>]*>(?P<label>.*?)</a>(\s*</sup>)?',
            re.IGNORECASE | re.DOTALL,
        )

        referenced_fragments: set[str] = set()
        referenced_fragments_lower: set[str] = set()
        for match in anchor_pattern.finditer(markup):
            fragment = match.group("fragment")
            if not fragment:
                continue
            referenced_fragments.add(fragment)
            referenced_fragments_lower.add(fragment.lower())

        footnote_pattern = re.compile(
            r'<(?P<tag>div|p|section|aside|li)[^>]*id="(?P<id>[^"]+)"[^>]*>(?P<body>.*?)</(?P=tag)>',
            re.IGNORECASE | re.DOTALL,
        )
        footnote_map: Dict[str, str] = {}

        def looks_like_footnote_id(foot_id: str) -> bool:
            if not foot_id:
                return False
            lowered = foot_id.lower()
            if lowered in referenced_fragments_lower or foot_id in referenced_fragments:
                return True
            if re.search(r"(foot|note|rodape|rodapé)", lowered):
                return True
            if re.match(r"(?:fn|n|nota|rodape|rodapé)[\w\-]*\d*$", lowered):
                return True
            return False

        def capture(match: re.Match) -> str:
            foot_id = match.group("id")
            if not looks_like_footnote_id(foot_id):
                return match.group(0)
            body = match.group("body")
            plain = TextProcessor.html_to_plain_text(body)
            cleaned = TextProcessor.normalise_whitespace(plain)
            footnote_map[foot_id] = cleaned
            lower_id = foot_id.lower()
            if lower_id not in footnote_map:
                footnote_map[lower_id] = cleaned
            return ""

        markup_without_footnotes = footnote_pattern.sub(capture, markup)

        footnotes: List[Dict[str, str]] = []
        note_numbers: Dict[str, str] = {}
        counter = 0

        def replace(match: re.Match) -> str:
            nonlocal counter
            fragment = match.group("fragment")
            fragment_key = fragment.lower()
            if fragment not in footnote_map and fragment_key not in footnote_map:
                return match.group(0)
            lookup_key = fragment if fragment in footnote_map else fragment_key
            label = TextProcessor.html_to_plain_text(match.group("label"))
            label_digits = "".join(ch for ch in label if ch.isdigit())
            is_superscript = bool(match.group(1))
            fragment_hint = bool(
                re.search(r"(foot|fn|note|rodape|rodapé)\w*", fragment_key, re.IGNORECASE)
            )
            if label_digits.isdigit() and not is_superscript and not fragment_hint:
                # Numeric internal links can be section anchors, not footnotes.
                return match.group(0)
            digits = label_digits
            if fragment_key in note_numbers:
                number = note_numbers[fragment_key]
            else:
                number = digits if digits else str(len(note_numbers) + 1)
                note_numbers[fragment_key] = number
            counter += 1
            marker_token = f"[[FOOTNOTE_{counter}]]"
            footnote_text = footnote_map.get(lookup_key, "").strip()

            # Remove duplicate number/label at the beginning of the text
            if digits:
                # Try to remove various forms of the number at the beginning
                candidates = [
                    f"[{digits}]",
                    f"({digits})",
                    f"{digits}.",
                    f"{digits}:",
                    f"{digits}-",
                    f"[{label}]",
                    f"({label})",
                    f"{label}.",
                    f"{label}:",
                    f"{label}-",
                    digits,  # Just the number
                ]
                lowered = footnote_text.lower()
                for candidate in candidates:
                    if lowered.startswith(candidate.lower()):
                        footnote_text = footnote_text[len(candidate) :].lstrip(" .:-)–—")
                        break

            if not footnote_text:
                footnote_text = footnote_map.get(lookup_key, "").strip()
            footnotes.append(
                {
                    "marker": marker_token,
                    "number": number,
                    "text": TextProcessor.normalise_whitespace(footnote_text),
                    "original_text": TextProcessor.normalise_whitespace(
                        footnote_map.get(lookup_key, "")
                    ),
                }
            )
            return marker_token

        markup_with_markers = anchor_pattern.sub(replace, markup_without_footnotes)
        return markup_with_markers, footnotes

    @staticmethod
    def _render_footnotes(
        base_text: str,
        footnotes: List[Dict[str, str]],
        *,
        mode: str,
        context_words: int,
        phrases: Optional[Dict[str, str]] = None,
    ) -> str:
        if not footnotes:
            return base_text

        mode = (mode or "inline").lower()
        context_words = max(int(context_words or 0), 0)

        phrases = phrases or {}
        # Default template uses paragraph breaks and ellipses around footnotes so
        # the TTS engine produces clear pauses, separating the note from the main
        # text flow.  "..." signals a long silence to Edge-TTS; the double newlines
        # create paragraph-level pauses for all engines.
        prefix = phrases.get("prefix", "\n\n")
        template = phrases.get("template", "nota de rodapé {number}...\n{text}")
        suffix_text = phrases.get("suffix_text", "\nfim da nota de rodapé...")
        closing = phrases.get("closing", "\n\n")
        chapter_end_template = phrases.get(
            "chapter_end_template",
            "nota de rodapé {number}...\n{snippet} — {text}\nfim da nota de rodapé...",
        )

        text = base_text

        if mode == "inline":
            for footnote in footnotes:
                marker = footnote["marker"]
                intro = template.format(number=footnote["number"], text=footnote["text"])
                suffix_part = suffix_text.format(number=footnote["number"], text=footnote["text"])
                replacement = f"{prefix}{intro}{suffix_part}{closing}"
                text = text.replace(marker, replacement, 1)
            return text

        appended_entries: List[Tuple[str, str, str]] = []
        for footnote in footnotes:
            marker = footnote["marker"]
            while marker in text:
                idx = text.find(marker)
                if idx == -1:
                    break
                preceding = text[:idx]
                snippet = TextProcessor._extract_context_snippet(preceding, context_words)
                text = text[:idx] + text[idx + len(marker) :]
                if mode == "chapter_end":
                    appended_entries.append((footnote["number"], snippet, footnote["text"]))
                break

            if mode == "chapter_end" and appended_entries:
                lines = []
                for number, snippet, note_text in appended_entries:
                    snippet_part = (snippet or "context not identified").strip()
                    line = chapter_end_template.format(
                        number=number,
                        text=note_text,
                        snippet=snippet_part,
                    )
                    lines.append(line)
                text = text.rstrip() + "\n\n" + "\n".join(lines)

        return text

    @staticmethod
    def _apply_footnotes_to_segments(
        segments: Optional[List[FormattingSegment]],
        footnotes: List[Dict[str, str]],
        *,
        mode: str,
        context_words: int,
        phrases: Optional[Dict[str, str]] = None,
    ) -> Optional[List[FormattingSegment]]:
        if not segments or not footnotes:
            return segments

        mode = (mode or "inline").lower()
        if mode != "inline":
            return segments

        phrases = phrases or {}
        prefix = phrases.get("prefix", "\n\n")
        template = phrases.get("template", "nota de rodapé {number}...\n{text}")
        suffix_text = phrases.get("suffix_text", "\nfim da nota de rodapé...")
        closing = phrases.get("closing", "\n\n")

        replacements: Dict[str, str] = {}
        for footnote in footnotes:
            intro = template.format(number=footnote["number"], text=footnote["text"])
            suffix_part = suffix_text.format(number=footnote["number"], text=footnote["text"])
            replacements[footnote["marker"]] = f"{prefix}{intro}{suffix_part}{closing}"

        for segment in segments:
            if not getattr(segment, "text", None):
                continue
            updated = segment.text
            for marker, replacement in replacements.items():
                if marker in updated:
                    updated = updated.replace(marker, replacement)
            segment.text = updated

        return segments

    @staticmethod
    def _extract_context_snippet(preceding_text: str, words: int) -> str:
        if words <= 0 or not preceding_text:
            return ""
        window = preceding_text[-200:]
        tokens = window.strip().split()
        if not tokens:
            return ""
        snippet_tokens = tokens[-words:]
        snippet = " ".join(snippet_tokens)
        return snippet.strip(" -–—,:;·\"'“”‘’")

    @staticmethod
    def html_to_text(content: str) -> str:
        if not content:
            return ""
        text = TextProcessor.strip_ignored_html_blocks(str(content))
        text = NBSP_RE.sub(" ", text)
        text = ARTIFACT_RE.sub(" ", text)
        text = PARA_BLOCK_RE.sub("\n", text)
        text = TextProcessor.strip_html_tags(text)
        text = PAGE_BREAK_RE.sub("\n", text)
        text = WHITESPACE_RE.sub(" ", text)
        text = re.sub(r"\n{2,}", "\n", text)
        return text.strip()

    @staticmethod
    def add_pause_before_dash(text: str) -> str:
        if not text:
            return ""

        def insert_break(match: re.Match) -> str:
            preceding = match.group(1)
            dash = match.group(2)
            trailing = match.group(3)
            return f"{preceding}\n{dash}{trailing}"

        pattern = re.compile(r"([^\s\n])\s*(—)(\s*)")
        updated = pattern.sub(insert_break, text)
        return updated

    @staticmethod
    def extract_title(markup: str, fallback: str) -> str:
        match = H_TAG.search(markup)
        if match:
            heading = TextProcessor.strip_html_tags(match.group(2)).strip()
            if heading:
                return heading
        # Fallback to the first meaningful words of the content
        text = TextProcessor.html_to_text(markup)
        if not text:
            return fallback
        words = text.split()
        max_words = 6
        truncated = len(words) > max_words
        if truncated:
            text = " ".join(words[:max_words])
            return text.rstrip(".,;:!?") or fallback
        return text.strip()

    @staticmethod
    def normalise_whitespace(text: str) -> str:
        return WHITESPACE_RE.sub(" ", text.strip())

    @staticmethod
    def join_broken_lines(text: str) -> str:
        """Join lines broken in the middle of sentences (typical in PDFs).

        Preserves real paragraph breaks (lines ending with punctuation).
        Removes repeated headers/footers that appear on multiple pages.
        """
        if not text:
            return ""

        lines = text.split("\n")

        # First: detect and remove repeated headers/footers
        lines = TextProcessor._remove_pdf_headers_footers(lines)

        joined_lines = []
        i = 0

        while i < len(lines):
            current_line = lines[i].strip()

            if not current_line:
                i += 1
                continue

            # Check if line ends with punctuation indicating end of sentence
            ends_with_punctuation = current_line.endswith((".", "!", "?", ":", ";"))

            # If it doesn't end with punctuation AND there's a next line, try to join
            while not ends_with_punctuation and i + 1 < len(lines):
                next_line = lines[i + 1].strip()

                # If next line is empty, stop joining
                if not next_line:
                    break

                # Join with space
                current_line = current_line + " " + next_line
                i += 1

                # Update punctuation flag
                ends_with_punctuation = current_line.endswith((".", "!", "?", ":", ";"))

            joined_lines.append(current_line)
            i += 1

        return "\n".join(joined_lines)

    @staticmethod
    def _remove_pdf_headers_footers(lines: List[str]) -> List[str]:
        """Remove repeated headers and footers typical of PDFs.

        Detects short lines that appear isolated (without continuation) and that
        look like book titles, author names, or page numbers.
        """
        if not lines or len(lines) < 3:
            return lines

        # Heuristics to identify headers/footers:
        # 1. Very short lines (< 100 chars) that don't end with normal punctuation
        # 2. Lines that contain only numbers (page number)
        # 3. Lines that look like titles (no verbs, capitalized words)

        filtered_lines = []

        # First: analyze common patterns in the first and last lines
        # Headers/footers are usually in the first 3-4 or last 3-4 lines
        for i, line in enumerate(lines):
            stripped = line.strip()

            # Empty line, keep
            if not stripped:
                filtered_lines.append(line)
                continue

            # Line is just a number (page number)
            if stripped.isdigit():
                continue

            # Check if it's one of the first or last non-empty lines
            is_header_position = i < 5
            is_footer_position = i >= len(lines) - 5

            # Short line in header/footer position
            if (is_header_position or is_footer_position) and len(stripped) < 100:
                # Check if it looks like a header/footer
                words = stripped.split()

                # Remove if it's just a title with capitalized words
                if len(words) >= 2:
                    cap_count = sum(1 for w in words if w and len(w) > 1 and w[0].isupper())
                    # If most words are capitalized and it doesn't end with punctuation
                    if cap_count >= len(words) * 0.6 and not stripped.endswith(
                        (".", "!", "?", ":")
                    ):
                        # Likely book title/author
                        continue

                # Remove lines that are just "Página X" or similar
                if stripped.lower().startswith("página") or stripped.lower().startswith("pagina"):
                    continue

            filtered_lines.append(line)

        return filtered_lines

    @staticmethod
    def looks_like_css(content: str) -> bool:
        if not content:
            return False
        lowered = content.lower()
        css_signals = ["@page", "@media", "{", "font-family", "margin:", "padding:"]
        signal_count = sum(1 for token in css_signals if token in lowered)
        if signal_count < 2:
            return False
        if "<html" in lowered or "<body" in lowered or "<div" in lowered:
            return False
        return True

    @staticmethod
    def extract_first_heading(content: Optional[str]) -> Optional[str]:
        if not content:
            return None
        match = H_TAG.search(content)
        if not match:
            return None
        heading = TextProcessor.strip_html_tags(match.group(2))
        return TextProcessor.normalise_whitespace(heading)

    @staticmethod
    def extract_structural_titles(
        content: Optional[str], chapter_title: Optional[str] = None
    ) -> List[str]:
        titles: List[str] = []
        seen: set[str] = set()

        _p_tag = re.compile(r"<p\b[^>]*>(.*?)</p>", re.I | re.DOTALL)

        def _add(raw: str) -> None:
            norm = TextProcessor.normalise_whitespace(
                NBSP_RE.sub(" ", TextProcessor.strip_html_tags(raw))
            )
            key = norm.casefold()
            if norm and key not in seen:
                seen.add(key)
                titles.append(norm)

        if content:
            for match in H_TAG.finditer(content):
                _add(match.group(2))

            # Scan <p> elements for structural titles (subtitles, author attributions,
            # section labels) that look like headings: ≤ 8 words, no terminal punctuation.
            # When h tags exist, stop at the first paragraph that looks like body text
            # (long or ends with sentence punctuation) — this captures attribution lines
            # such as "DE BRUNO TOLENTINO" after an "PREFÁCIO" h1.
            # When no h tags are present, preserve the original behaviour: scan all
            # <p> elements up to the 6-title limit (e.g. pt-BR IT edition).
            _has_h_tags = H_TAG.search(content) is not None
            for p_match in _p_tag.finditer(content):
                raw = TextProcessor.strip_html_tags(p_match.group(1)).strip()
                norm = TextProcessor.normalise_whitespace(NBSP_RE.sub(" ", raw))
                if norm and len(norm.split()) <= 8 and norm[-1] not in ".!?":
                    _add(p_match.group(1))
                elif _has_h_tags:
                    # First body-like paragraph signals end of the opening block.
                    break
                if len(titles) >= 6:
                    break

        if chapter_title:
            normalised = TextProcessor.clean_chapter_title(chapter_title)
            _add(normalised)
            # Also add each segment split on em-dash / colon separators so that
            # EPUBs using <p> for headings (e.g. pt-BR editions) still get
            # individual heading lines recognised as title keys.
            # Example: "Capítulo 3 – Seis telefonemas (1985)" → ["Capítulo 3",
            #           "Seis telefonemas (1985)"]
            for part in re.split(r"\s*[–—:]\s*", normalised):
                part = part.strip()
                if part and len(part) > 3:
                    _add(part)

        return titles

    @staticmethod
    def _first_nonempty_line(text: str) -> str:
        for line in text.split("\n"):
            normalised = TextProcessor.normalise_whitespace(line)
            if normalised:
                return normalised
        return ""

    @staticmethod
    def _first_nonempty_lines(text: str, limit: int = 2) -> List[str]:
        lines: List[str] = []
        for line in text.split("\n"):
            normalised = TextProcessor.normalise_whitespace(line)
            if normalised:
                lines.append(normalised)
                if len(lines) >= limit:
                    break
        return lines

    @staticmethod
    def _structural_key(text: str) -> str:
        compact = text.casefold()
        compact = re.sub(r"[^\w\s]", " ", compact)
        return re.sub(r"\s+", " ", compact).strip()

    @staticmethod
    def apply_structural_speech_cues(
        text: str,
        raw_html: Optional[str] = None,
        chapter_title: Optional[str] = None,
    ) -> str:
        if not text:
            return ""

        updated = text
        titles = TextProcessor.extract_structural_titles(raw_html, chapter_title)
        if not titles:
            return updated

        first_line = TextProcessor._first_nonempty_line(updated)
        opening_preview = " ".join(TextProcessor._first_nonempty_lines(updated, limit=4))
        toc_title = TextProcessor.clean_chapter_title(chapter_title or "")
        first_line_key = TextProcessor._structural_key(first_line)
        opening_key = TextProcessor._structural_key(opening_preview)
        toc_title_key = TextProcessor._structural_key(toc_title)
        # Prepend the chapter title so the TTS announces it. Suppress only when
        # the title is already the first line, OR when the title is substantive
        # enough that a fuzzy overlap with the opening is reliable evidence of
        # duplication. Short/numeric titles (e.g. "1", "Chapter 2") always get
        # announced — they collide with incidental digits/words in the opening
        # otherwise, silently dropping the announcement.
        should_prepend = bool(toc_title) and first_line_key != toc_title_key
        if should_prepend:
            toc_tokens = toc_title_key.split()
            substantive = len(toc_title_key) >= 10 and len(toc_tokens) >= 2
            if substantive and (
                opening_key.startswith(toc_title_key)
                or toc_title_key.startswith(opening_key)
                or toc_title_key in opening_key
            ):
                should_prepend = False
        if should_prepend:
            updated = f"{toc_title}\n{updated}"

        title_keys = {title.casefold() for title in titles}
        adjusted_lines: List[str] = []
        for line in updated.split("\n"):
            stripped = TextProcessor.normalise_whitespace(line)
            if stripped and stripped.rstrip(".!?;:").casefold() in title_keys:
                # End the title line with a single period. Earlier
                # versions used "..." (ellipsis), but Edge sometimes
                # interpreted the ellipsis as a stutter cue and
                # inserted a 100-150 ms gap INSIDE the previous word
                # ("Capí..tulo 2"), producing the artefact the user
                # reported as "Capi..........tulo22". A single period
                # gives the same ~500 ms sentence-end pause without
                # the stutter risk; the long beat between title and
                # body still comes from `inject_silence_at_offset`
                # in converter.py.
                adjusted_lines.append(f"{stripped.rstrip('.!?;:')}.")
            else:
                adjusted_lines.append(line)

        result = "\n".join(adjusted_lines)

        # Normalize "<N> |" chapter-number markers (common in pt-BR EPUBs
        # where each chapter starts with e.g. "1 |") so the TTS pauses
        # between the announcement, the chapter number, and the body.
        # Without this, Edge reads "Capítulo 1 1 A transformação..." in a
        # single breath; with the ellipsis split, listeners hear
        # "Capítulo 1... 1... A transformação...". The pipe `|` is a
        # purely visual separator in the source EPUB and gets dropped.
        # The trailing `[.!?]?` absorbs any period that
        # `enhance_natural_pauses` might have appended to the line
        # before this normalisation pass (it tags un-punctuated
        # paragraph-end lines with a period).
        # Drop pt-BR EPUB "<N> |" / "## <N>" / bare-numeric chapter-
        # start markers entirely. Earlier versions tried to convert them
        # into "<N>...", then "<N>." + blank line, but plain-text Edge
        # caps inter-sentence pauses at ~700 ms regardless of how many
        # periods or newlines you stack, so the result still sounded
        # like one continuous breath ("Capítulo 1 1 a transformação").
        # The chapter title announcement ("Capítulo 1.") at the top
        # already fills the same role; the standalone "1" is a printed
        # artifact with no listener value, so suppress it.
        result = re.sub(
            r"(^|\n)\s*(\d+)\s*\|\s*[.!?]?\s*(\n|$)",
            lambda m: f"{m.group(1)}{m.group(3)}",
            result,
        )
        result = re.sub(
            r"(^|\n)\s*##+\s*(\d{1,3})\s*[.!?]?\s*(\n|$)",
            lambda m: f"{m.group(1)}{m.group(3)}",
            result,
        )
        result = re.sub(
            r"(^|\n)(\d{1,3})\s*\n(\s*\S)",
            lambda m: f"{m.group(1)}{m.group(3)}",
            result,
        )

        return result

    @staticmethod
    def extract_title_from_text(text: Optional[str], max_words: int = 6) -> str:
        if not text:
            return ""
        cleaned = str(text).replace("\r", " ").replace("\n", " ").replace("\f", " ")
        cleaned = cleaned.replace("\t", " ")
        cleaned = TextProcessor.normalise_whitespace(cleaned)
        if not cleaned:
            return ""
        words = cleaned.split()
        if len(words) <= max_words:
            return " ".join(words)
        return " ".join(words[:max_words])


_TOC_CACHE_MAX = 16
_toc_cache: "OrderedDict[Tuple[str, int, str], List[TocItem]]" = OrderedDict()


def _toc_disk_cache_path(file_path: str) -> Optional[Path]:
    """Compute the on-disk TOC cache path for a given EPUB. Returns
    ``None`` when paths cannot be resolved.
    """
    try:
        from .paths import CACHE_DIR  # type: ignore

        # blake2b digest_size=8 → 16 hex chars, matching the previous
        # sha1[:16] surface so existing disk filenames are still readable
        # in length terms. The hash itself is different, so v0.3.24/v0.3.25
        # entries become orphans on first run after this change — they
        # are cleared by ``_toc_disk_cache_cleanup`` once they age past 30d.
        if hashlib is None:
            return None
        digest = hashlib.blake2b(
            str(file_path).encode("utf-8", errors="ignore"), digest_size=8
        ).hexdigest()
        return Path(CACHE_DIR) / "_toc" / f"{digest}.json"
    except Exception:
        return None


_TOC_DISK_CACHE_CLEANED: bool = False


def _toc_disk_cache_cleanup(max_age_days: int = 30) -> int:
    """Drop ``.cache/_toc/`` entries older than ``max_age_days``.

    Run lazily — every EPUB ever opened leaves a sha1 entry behind, and
    over months that grows unboundedly. Returns the number of entries
    removed (0 when the dir is missing). Idempotent within a process: the
    sweep runs once per process, gated by ``_TOC_DISK_CACHE_CLEANED``.
    """
    global _TOC_DISK_CACHE_CLEANED
    if _TOC_DISK_CACHE_CLEANED:
        return 0
    _TOC_DISK_CACHE_CLEANED = True
    try:
        from .paths import CACHE_DIR  # type: ignore

        toc_dir = Path(CACHE_DIR) / "_toc"
    except Exception:
        return 0
    if not toc_dir.exists() or not toc_dir.is_dir():
        return 0
    cutoff = time.time() - max(1, max_age_days) * 86400
    removed = 0
    try:
        entries = list(toc_dir.iterdir())
    except OSError:
        return 0
    for entry in entries:
        if not entry.is_file():
            continue
        try:
            if entry.stat().st_mtime < cutoff:
                entry.unlink()
                removed += 1
        except OSError:
            continue
    return removed


def _toc_to_jsonable(items: List["TocItem"]) -> list:
    """Serialize TocItem tree to plain dicts."""
    out = []
    for it in items:
        out.append(
            {
                "title": it.title,
                "href": it.href,
                "level": it.level,
                "children": _toc_to_jsonable(it.children) if it.children else [],
            }
        )
    return out


def _toc_from_jsonable(data: list) -> List["TocItem"]:
    out: List[TocItem] = []
    for entry in data or []:
        children = _toc_from_jsonable(entry.get("children") or [])
        out.append(
            TocItem(
                title=entry.get("title", "") or "",
                href=entry.get("href", "") or "",
                level=int(entry.get("level") or 1),
                children=children,
            )
        )
    return out


def _toc_cache_get(file_path: str, opf_path: Optional[str]) -> Optional[List[TocItem]]:
    try:
        mtime_ns = os.stat(file_path).st_mtime_ns
    except OSError:
        return None
    key = (file_path, mtime_ns, opf_path or "")
    hit = _toc_cache.get(key)
    if hit is not None:
        _toc_cache.move_to_end(key)
        return list(hit)
    # Persistent cache: same EPUB across CLI runs reuses the parsed TOC
    # without paying the XML walk again. Keyed on mtime_ns + opf_path so
    # an edition swap (different EPUB at the same path) invalidates.
    disk_path = _toc_disk_cache_path(file_path)
    if disk_path is not None and disk_path.exists():
        try:
            payload = json.loads(disk_path.read_text(encoding="utf-8"))
            if (
                isinstance(payload, dict)
                and int(payload.get("mtime_ns") or 0) == mtime_ns
                and (payload.get("opf_path") or "") == (opf_path or "")
            ):
                items = _toc_from_jsonable(payload.get("toc") or [])
                # Promote into the in-memory LRU.
                _toc_cache[key] = list(items)
                while len(_toc_cache) > _TOC_CACHE_MAX:
                    _toc_cache.popitem(last=False)
                return list(items)
        except Exception:
            pass
    return None


def _toc_cache_put(file_path: str, opf_path: Optional[str], items: List[TocItem]) -> None:
    try:
        mtime_ns = os.stat(file_path).st_mtime_ns
    except OSError:
        return
    key = (file_path, mtime_ns, opf_path or "")
    _toc_cache[key] = list(items)
    while len(_toc_cache) > _TOC_CACHE_MAX:
        _toc_cache.popitem(last=False)
    # Lazy GC of stale persistent entries — runs once per process the
    # first time a TOC is written. Keeps the disk cache bounded across
    # months of use without any explicit maintenance step.
    try:
        _toc_disk_cache_cleanup()
    except Exception:
        pass
    # Best-effort persistent cache write.
    disk_path = _toc_disk_cache_path(file_path)
    if disk_path is not None:
        try:
            disk_path.parent.mkdir(parents=True, exist_ok=True)
            disk_path.write_text(
                json.dumps(
                    {
                        "mtime_ns": mtime_ns,
                        "opf_path": opf_path or "",
                        "toc": _toc_to_jsonable(items),
                    }
                ),
                encoding="utf-8",
            )
        except Exception:
            pass


class EpubParser:
    """Parse a single EPUB file into a :class:`Book` instance."""

    def __init__(
        self,
        file_path: str | Path,
        paragraph_split_chars: int = 0,
    ) -> None:
        self.file_path = str(file_path)
        self.path = Path(file_path)
        # 0 means "use SUBCHAPTER_MAX_CHARS default computed from env vars"
        self.paragraph_split_chars = paragraph_split_chars or SUBCHAPTER_MAX_CHARS

    @staticmethod
    def _prepare_speech_text(
        text: str,
        formatting_segments: Optional[List[FormattingSegment]],
        *,
        raw_html: Optional[str] = None,
        chapter_title: Optional[str] = None,
    ) -> str:
        """
        Prepare text for TTS submission with audible formatting cues.

        This method:
        1. PRESERVES [[lang:xx]] tags for multilingual TTS
        2. Converts [[fmt:...]] markers into messages the listener understands ("in italics", "in quotes", etc.)
        3. Removes only auxiliary markdown (_italic_, **bold**) that doesn't contribute to audio

        Result: the returned text is exactly the payload sent to TTS and saved in -pre-tts.txt
        """
        if not text:
            return ""

        prepared_text = text
        if TextFormattingProcessor:
            try:
                prepared_text = TextFormattingProcessor.enhance_natural_pauses(prepared_text)
            except Exception:
                prepared_text = text

        # Only remove inline markdown that was added by the processor
        # IMPORTANT: Do NOT remove [[lang:]] or [[fmt:]] tags
        if TextFormattingProcessor:
            formatter = TextFormattingProcessor()
            try:
                processed = formatter.to_audible_text(prepared_text, formatting_segments)
                if processed:
                    structured = TextProcessor.apply_structural_speech_cues(
                        processed,
                        raw_html=raw_html,
                        chapter_title=chapter_title,
                    )
                    enhanced = TextFormattingProcessor.enhance_natural_pauses(structured)
                    return TextProcessor.apply_structural_speech_cues(
                        enhanced,
                        raw_html=raw_html,
                        chapter_title=chapter_title,
                    )
            except Exception:
                # Fallback to basic removal if something fails
                pass
            fallback = TextProcessor.apply_structural_speech_cues(
                TextFormattingProcessor.strip_inline_markdown(prepared_text),
                raw_html=raw_html,
                chapter_title=chapter_title,
            )
            enhanced_fallback = TextFormattingProcessor.enhance_natural_pauses(fallback)
            return TextProcessor.apply_structural_speech_cues(
                enhanced_fallback,
                raw_html=raw_html,
                chapter_title=chapter_title,
            )

        return prepared_text

    def parse(self) -> Book:
        with zipfile.ZipFile(self.path, "r") as archive:
            opf_path = self._find_opf_path(archive)
            manifest, spine_ids, title, author, language = self._parse_opf(archive, opf_path)
            base_dir = self._opf_dir(opf_path)
            toc = self._parse_toc(archive, base_dir, opf_path=opf_path)
            toc_title_map = self._build_toc_title_map(toc, base_dir)

            # Use spine-based method (reliable, preserves all content)
            chapters = self._extract_chapters(
                archive,
                manifest,
                spine_ids,
                base_dir,
                toc_title_map=toc_title_map,
                toc=toc,
            )

        # Assign hierarchy levels from TOC so callers can distinguish
        # top-level parts (level=1) from subchapters (level=2, 3, …).
        self._assign_levels_from_toc(chapters, toc, base_dir)

        title = title or self.path.stem
        author = author or ""
        return Book(
            title=title.strip(),
            author=author.strip(),
            chapters=chapters,
            toc=toc,
            language=language,
        )

    def _find_opf_path(self, archive: zipfile.ZipFile) -> str:
        try:
            container_xml = archive.read("META-INF/container.xml").decode("utf-8")
        except KeyError as exc:
            raise RuntimeError("Invalid EPUB: missing container.xml") from exc

        container = ET.fromstring(container_xml)
        rootfile = container.find(".//ocf:rootfile", XML_NS)
        if rootfile is None or "full-path" not in rootfile.attrib:
            raise RuntimeError("Invalid EPUB: container has no rootfile")
        return rootfile.attrib["full-path"]

    def _parse_opf(
        self,
        archive: zipfile.ZipFile,
        opf_path: str,
    ) -> Tuple[Dict[str, str], List[str], str, str, Optional[str]]:
        opf_content = self._read_zip_text(archive, opf_path)
        opf_tree = ET.fromstring(opf_content)

        manifest: Dict[str, str] = {}
        for item in opf_tree.findall("opf:manifest/opf:item", XML_NS):
            item_id = item.attrib.get("id")
            href = item.attrib.get("href")
            if item_id and href:
                manifest[item_id] = href

        spine: List[str] = []
        for itemref in opf_tree.findall("opf:spine/opf:itemref", XML_NS):
            idref = itemref.attrib.get("idref")
            if idref and idref in manifest:
                spine.append(idref)

        title = ""
        author = ""
        language = None
        metadata = opf_tree.find("opf:metadata", XML_NS)
        if metadata is not None:
            title_elem = metadata.find("dc:title", XML_NS)
            author_elem = metadata.find("dc:creator", XML_NS)
            language_elem = metadata.find("dc:language", XML_NS)
            if title_elem is not None and title_elem.text:
                title = title_elem.text.strip()
            if author_elem is not None and author_elem.text:
                author = author_elem.text.strip()
            if language_elem is not None and language_elem.text:
                # Normalize to lowercase 2-letter code (e.g., 'en-US' -> 'en')
                lang_code = language_elem.text.strip().lower()
                language = lang_code.split("-")[0] if lang_code else None

        return manifest, spine, title, author, language

    def _extract_chapters_from_toc(
        self,
        archive: zipfile.ZipFile,
        manifest: Dict[str, str],
        spine_ids: Iterable[str],
        base_dir: str,
        toc: List[TocItem],
    ) -> List[Chapter]:
        """Extract chapters based on the TOC (Table of Contents) structure.

        This avoids content duplication by using the book's actual hierarchy.
        """
        chapters: List[Chapter] = []
        index_counter = 1
        context_words = 8

        # Cache of already-read HTML content
        html_cache: Dict[str, str] = {}
        # Track already-processed files (without anchor)
        processed_full_files: set = set()

        def get_html_content(href: str) -> str:
            """Get HTML content from a file, using cache."""
            # Extract only the file (without anchor)
            file_path = href.split("#")[0] if "#" in href else href
            if not file_path:
                return ""

            if file_path in html_cache:
                return html_cache[file_path]

            asset_path = self._join_path(base_dir, file_path)
            try:
                content = self._read_zip_text(archive, asset_path)
                html_cache[file_path] = content
                return content
            except KeyError:
                return ""

        def get_all_split_files_content(href: str) -> str:
            """Get content from all related split files.

            If the file is part0006_split_000.html, also loads:
            part0006_split_001.html, part0006_split_002.html, etc.
            """
            file_path = href.split("#")[0] if "#" in href else href
            if not file_path:
                return ""

            # Check if it's a split file
            if "_split_" in file_path:
                # Extract base and split number
                base_pattern = file_path.rsplit("_split_", 1)[0]

                # Collect all splits of this file
                all_content = []
                split_num = 0

                while True:
                    split_file = f"{base_pattern}_split_{split_num:03d}.html"
                    content = get_html_content(split_file)
                    if content:
                        all_content.append(content)
                        split_num += 1
                    else:
                        break

                if all_content:
                    return "\n".join(all_content)

            # If it's not a split or no splits were found, return single file
            return get_html_content(href)

        def process_toc_item(item: TocItem, level: int = 1) -> None:
            """Process a TOC item and its children recursively."""
            nonlocal index_counter

            # Extract file and anchor
            if "#" in item.href:
                file_path_only = item.href.split("#")[0]
                anchor = item.href.split("#")[1]
            else:
                file_path_only = item.href
                anchor = ""

            # For split files, use base without split number
            base_file = file_path_only
            if "_split_" in file_path_only:
                base_file = file_path_only.rsplit("_split_", 1)[0]

            # If there's no anchor and the file/base was already processed, skip
            if not anchor and base_file in processed_full_files:
                return

            # Get HTML content of this item (including all splits)
            raw_content = get_all_split_files_content(item.href)
            if not raw_content or TextProcessor.looks_like_css(raw_content):
                return

            # Mark base as processed
            if not anchor:
                processed_full_files.add(base_file)

            # Create resolver for external footnotes
            file_path = item.href.split("#")[0] if "#" in item.href else item.href
            chapter_dir = str(Path(self._join_path(base_dir, file_path)).parent).replace("\\", "/")

            def resolve_external_file(relative_path: str) -> Optional[str]:
                try:
                    full_path = self._join_path(chapter_dir, relative_path)
                    return self._read_zip_text(archive, full_path)
                except (KeyError, Exception):
                    return None

            # Process text
            markup_with_markers, footnotes = TextProcessor.inject_footnotes(
                raw_content, external_file_resolver=resolve_external_file
            )
            text_with_formatting, formatting_segments = (
                TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
            )

            if footnotes:
                text_with_footnotes = TextProcessor._render_footnotes(
                    text_with_formatting,
                    footnotes,
                    mode="inline",
                    context_words=context_words,
                )
                formatting_segments = TextProcessor._apply_footnotes_to_segments(
                    formatting_segments,
                    footnotes,
                    mode="inline",
                    context_words=context_words,
                )
            else:
                text_with_footnotes = text_with_formatting

            text = TextProcessor.add_pause_before_dash(text_with_footnotes)

            # Use TOC title
            raw_title = item.title.strip() if item.title else f"Chapter {index_counter}"
            chapter_title = TextProcessor.clean_chapter_title(raw_title)

            # Prepare speech text
            speech_text = self._prepare_speech_text(
                text,
                formatting_segments,
                raw_html=raw_content,
                chapter_title=chapter_title,
            )

            # Create chapter
            chapters.append(
                Chapter(
                    index=index_counter,
                    name=chapter_title,
                    source_path=item.href,
                    text=text or "",
                    level=level,
                    raw_html=raw_content,
                    formatting_segments=formatting_segments,
                    footnotes=list(footnotes) if footnotes else None,
                    speech_text=speech_text or "",
                )
            )
            index_counter += 1

            # Do NOT process children - use only level 1 TOC items
            # to avoid content duplication

        # Process only level 1 TOC items (main chapters)
        for toc_item in toc:
            process_toc_item(toc_item, level=1)

        return chapters

    @staticmethod
    def _build_toc_index_map(toc: List["TocItem"]) -> Dict[str, Any]:
        """Build a file-href → hierarchical index mapping for a nested TOC.

        Level-1 items receive integer indices (1, 2, 3, …).
        Level-2 children receive string indices ``"N.M"`` where N is the
        parent's integer index and M is the child's position within that parent.
        Only the first occurrence of each file wins (URL anchors are stripped).

        Returns an empty dict for flat TOCs that have no nested children.
        """
        result: Dict[str, Any] = {}
        for level1_idx, item in enumerate(toc, 1):
            file_href = item.href.split("#")[0] if "#" in item.href else item.href
            if file_href and file_href not in result:
                result[file_href] = level1_idx
            for level2_idx, child in enumerate(item.children, 1):
                child_href = child.href.split("#")[0] if "#" in child.href else child.href
                if child_href and child_href not in result:
                    result[child_href] = f"{level1_idx}.{level2_idx}"
        return result

    @staticmethod
    def _split_html_on_subchapter_markers(
        markup: str,
        parent_index,
        number_classes: frozenset,
        title_class: str,
    ) -> Optional[List[Tuple[str, str, str, bool]]]:
        """Split HTML markup at section-number / title element pairs.

        Looks for adjacent paragraph pairs:
          1. a section-number paragraph whose ``class`` attribute contains any
             member of *number_classes* (e.g. ``class_s3P-0`` for the first
             section, ``class_s42-0`` for subsequent sections in IT ch.11).
          2. a section-title paragraph whose ``class`` attribute contains
             *title_class* (e.g. ``class_sG5``), appearing within 500 chars
             after the number element.

        The HTML is split at each number-element position, so the number
        paragraph itself begins each fragment (not the title paragraph).
        Everything before the first pair is treated as the chapter preamble and
        prepended to the first fragment.

        Returns a list of ``(sub_index_str, sub_title, html_fragment)`` tuples
        ordered by appearance, or ``None`` when no qualifying pairs are found.
        """
        if not markup or not number_classes or not title_class:
            return None

        num_alt = "|".join(re.escape(c) for c in sorted(number_classes))
        number_re = re.compile(
            r'<p\b[^>]+\bclass="[^"]*(?:' + num_alt + r')[^"]*"[^>]*>.*?</p>',
            re.IGNORECASE | re.DOTALL,
        )
        title_re = re.compile(
            r'<p\b[^>]*\bclass="[^"]*' + re.escape(title_class) + r'[^"]*"[^>]*>(.*?)</p>',
            re.IGNORECASE | re.DOTALL,
        )
        any_p_re = re.compile(r"<p\b[^>]*>(.*?)</p>", re.IGNORECASE | re.DOTALL)

        num_matches = list(number_re.finditer(markup))
        if not num_matches:
            return None

        # For each number element look ahead for an adjacent title.
        # * Explicit title (class_sG5) is searched within 500 chars — tight window
        #   so a distant title from the next section is not mistakenly picked up.
        # * Fallback first-paragraph is searched within 2000 chars — wider window
        #   so long opening paragraphs (> 500 chars) are still found.
        # (start_pos, title_text, has_explicit_title)
        split_points: List[Tuple[int, str, bool]] = []
        for nm in num_matches:
            window_start = nm.end()
            title_window = markup[window_start : window_start + 500]
            tm = title_re.search(title_window)
            if tm:
                raw = TextProcessor.strip_html_tags(tm.group(1)).strip()
                split_points.append((nm.start(), raw or f"Section {len(split_points) + 1}", True))
            else:
                # No dedicated title element — derive title from first paragraph content.
                fallback_window = markup[window_start : window_start + 2000]
                any_p = any_p_re.search(fallback_window)
                if any_p:
                    raw = TextProcessor.strip_html_tags(any_p.group(1)).strip()
                    derived = raw[:57] + "..." if len(raw) > 60 else raw
                    split_points.append(
                        (nm.start(), derived or f"Section {len(split_points) + 1}", False)
                    )
                # If no paragraph in window at all, skip this number element.

        if not split_points:
            return None

        parent_idx = str(parent_index)
        preamble = markup[: split_points[0][0]]
        result: List[Tuple[str, str, str, bool]] = []

        for i, (start, title, has_explicit_title) in enumerate(split_points):
            sub_index = f"{parent_idx}.{i + 1}"
            frag_end = split_points[i + 1][0] if i + 1 < len(split_points) else len(markup)
            html_fragment = markup[start:frag_end]
            if i == 0:
                # Prepend chapter preamble (title, subtitle, etc.) to first subchapter.
                html_fragment = preamble + html_fragment
            result.append((sub_index, title, html_fragment, has_explicit_title))

        return result

    @staticmethod
    def _split_html_on_numeric_headings(
        markup: str,
        parent_index: Any,
        heading_tags: tuple = ("h3",),
    ) -> Optional[List[Tuple[str, str, str, bool]]]:
        """Split HTML at heading elements whose text is a bare integer.

        Used for EPUBs (e.g. IT) where chapter sections are marked with
        ``<h3>1</h3>``, ``<h3>2</h3>`` … instead of CSS-class ``<p>`` pairs.
        Returns the same ``(sub_index, sub_title, html_fragment, has_explicit_title)``
        format as ``_split_html_on_subchapter_markers``, or ``None`` when fewer
        than 2 qualifying headings are found (prevents false positives on chapters
        that happen to have a single numbered heading).
        """
        tag_alt = "|".join(re.escape(t) for t in heading_tags)
        heading_re = re.compile(
            r"<(" + tag_alt + r")\b[^>]*>(.*?)</\1>",
            re.IGNORECASE | re.DOTALL,
        )
        any_p_re = re.compile(r"<p\b[^>]*>(.*?)</p>", re.IGNORECASE | re.DOTALL)

        num_matches: List[Tuple[int, str]] = []
        for m in heading_re.finditer(markup):
            text = TextProcessor.strip_html_tags(m.group(2)).strip()
            if re.fullmatch(r"\d+", text):
                num_matches.append((m.start(), text))

        if len(num_matches) < 2:
            return None

        parent_idx = str(parent_index)
        preamble = markup[: num_matches[0][0]]
        result: List[Tuple[str, str, str, bool]] = []

        for i, (start, _section_num) in enumerate(num_matches):
            sub_index = f"{parent_idx}.{i + 1}"
            frag_end = num_matches[i + 1][0] if i + 1 < len(num_matches) else len(markup)
            html_fragment = markup[start:frag_end]
            if i == 0:
                html_fragment = preamble + html_fragment

            # Derive title from first paragraph after the heading.
            start + (
                num_matches[i + 1][0] - start if i + 1 < len(num_matches) else frag_end - start
            )
            # Start searching right after the heading tag itself
            heading_end = markup.find(">", start) + 1
            heading_close = markup.find(">", heading_end) + 1  # closing tag end
            fallback_window = markup[heading_close : heading_close + 2000]
            any_p = any_p_re.search(fallback_window)
            if any_p:
                raw = TextProcessor.strip_html_tags(any_p.group(1)).strip()
                derived = raw[:57] + "..." if len(raw) > 60 else raw
                sub_title = derived or f"Section {i + 1}"
            else:
                sub_title = f"Section {i + 1}"

            result.append((sub_index, sub_title, html_fragment, False))

        return result

    @staticmethod
    def _force_split_long_line(line: str, max_chars: int) -> List[str]:
        """Split a single line that exceeds max_chars at sentence then word boundaries.

        Tries sentence boundaries first ('. ', '! ', '? '), then word boundaries,
        finally hard-cuts at max_chars if no boundary is found.
        """
        if len(line) <= max_chars:
            return [line]
        parts: List[str] = []
        remaining = line
        while len(remaining) > max_chars:
            # Try to find a sentence boundary within the window
            window = remaining[:max_chars]
            cut = -1
            for sep in (". ", "! ", "? ", "; ", ", "):
                pos = window.rfind(sep)
                if pos > max_chars // 4:  # at least 25% into the chunk
                    cut = pos + len(sep)
                    break
            if cut < 0:
                # Fall back to last space
                pos = window.rfind(" ")
                cut = pos + 1 if pos > 0 else max_chars
            parts.append(remaining[:cut].rstrip())
            remaining = remaining[cut:].lstrip()
        if remaining:
            parts.append(remaining)
        return parts

    @staticmethod
    def _split_text_at_paragraph_boundaries(
        text: str,
        max_chars: int,
        parent_index,
    ) -> List[Tuple[str, str]]:
        """Split oversized plain text into chunks at line/sentence boundaries.

        EPUB plain text uses a single ``\\n`` between paragraphs (the
        html-to-text converter joins lines and strips blank lines).  This
        method splits on any newline, grouping lines until *max_chars* is
        reached, then flushing at the next line boundary.

        Lines that individually exceed *max_chars* (e.g. a wall of footnotes
        with no newlines) are further split at sentence, word, or hard-cut
        boundaries so no chunk ever exceeds *max_chars*.

        Returns a list of ``(index_str, text_fragment)`` tuples.  If no split
        is needed the list has one element with the original *parent_index*.
        """
        if len(text) <= max_chars:
            return [(str(parent_index), text)]

        parent_idx = str(parent_index)
        lines = text.split("\n")
        chunks: List[Tuple[str, str]] = []
        current_lines: List[str] = []
        current_len = 0
        part_num = 1

        def _flush() -> None:
            nonlocal part_num, current_lines, current_len
            chunks.append((f"{parent_idx}-{part_num}", "\n".join(current_lines)))
            part_num += 1
            current_lines = []
            current_len = 0

        for line in lines:
            # Force-split lines that are longer than max_chars on their own.
            sub_lines = (
                EpubParser._force_split_long_line(line, max_chars)
                if len(line) > max_chars
                else [line]
            )
            for sub in sub_lines:
                sub_len = len(sub)
                if current_lines and current_len + sub_len + 1 > max_chars:
                    _flush()
                current_lines.append(sub)
                current_len += sub_len + 1  # account for the \n separator

        if current_lines:
            if part_num == 1:
                # Nothing was flushed — all content fits in a single chunk; keep
                # the original (non-decimal) index so callers are not surprised.
                return [(parent_idx, "\n".join(current_lines))]
            chunks.append((f"{parent_idx}-{part_num}", "\n".join(current_lines)))

        return chunks

    def _prepare_spine_item(
        self,
        archive: zipfile.ZipFile,
        archive_lock: "threading.Lock",
        item_id: str,
        manifest: Dict[str, str],
        base_dir: str,
    ) -> Optional[Dict[str, Any]]:
        """Read + footnote-inject one spine file. Returns ``None`` when the
        file should be skipped (missing href, non-HTML, CSS-only, missing
        zip entry). All zip access is serialised through ``archive_lock``
        because :class:`zipfile.ZipFile` is not thread-safe.
        """
        href = manifest.get(item_id)
        if not href or not self._is_html_like(href):
            return None
        asset_path = self._join_path(base_dir, href)
        try:
            with archive_lock:
                raw_content = self._read_zip_text(archive, asset_path)
        except KeyError:
            return None
        if TextProcessor.looks_like_css(raw_content):
            return None
        chapter_dir = str(Path(asset_path).parent).replace("\\", "/") if "/" in asset_path else ""

        def resolve_external_file(relative_path: str) -> Optional[str]:
            try:
                full_path = self._join_path(chapter_dir, relative_path)
                with archive_lock:
                    return self._read_zip_text(archive, full_path)
            except (KeyError, Exception):
                return None

        markup_with_markers, footnotes = TextProcessor.inject_footnotes(
            raw_content, external_file_resolver=resolve_external_file
        )
        return {
            "item_id": item_id,
            "href": href,
            "asset_path": asset_path,
            "raw_content": raw_content,
            "markup_with_markers": markup_with_markers,
            "footnotes": footnotes,
        }

    def _extract_chapters(
        self,
        archive: zipfile.ZipFile,
        manifest: Dict[str, str],
        spine_ids: Iterable[str],
        base_dir: str,
        toc_title_map: Optional[Dict[str, str]] = None,
        toc: Optional[List[TocItem]] = None,
    ) -> List[Chapter]:
        import os as _os
        from concurrent.futures import ThreadPoolExecutor

        chapters: List[Chapter] = []
        index_counter = 1
        context_words = 8

        # When the TOC has nested items (e.g. Part > Chapter), build a
        # file-href → hierarchical index map so chapters inherit the TOC
        # hierarchy (e.g. Parte 2 = 5, Capítulo 4 = "5.1").
        has_nested_toc = toc is not None and any(item.children for item in toc)
        toc_index_map: Dict[str, Any] = self._build_toc_index_map(toc) if has_nested_toc else {}
        # Orphan counter for spine items that are not in the TOC index map.
        # Starts after the last level-1 TOC index to avoid collisions.
        _max_toc_idx = max(
            (v for v in toc_index_map.values() if isinstance(v, int)),
            default=0,
        )
        orphan_counter = _max_toc_idx

        # --- Pre-pass: parallel read + footnote injection -------------------
        # The zip read + footnote walk is the I/O-heaviest part of parsing
        # and is independent per spine item. We materialise the spine list,
        # parallelise the prep step (gated by env var, default on), then
        # iterate the prepared payload in spine order so the orphan_counter
        # and chapter assembly remain deterministic.
        spine_list = list(spine_ids)
        archive_lock = threading.Lock()
        parallel_enabled = _os.getenv("EPUB_PARSE_PARALLEL", "1").strip() != "0"
        max_workers = max(1, min(8, len(spine_list)))
        prepared: List[Optional[Dict[str, Any]]]
        if parallel_enabled and len(spine_list) > 4:
            with ThreadPoolExecutor(max_workers=max_workers) as ex:
                prepared = list(
                    ex.map(
                        lambda iid: self._prepare_spine_item(
                            archive, archive_lock, iid, manifest, base_dir
                        ),
                        spine_list,
                    )
                )
        else:
            prepared = [
                self._prepare_spine_item(archive, archive_lock, iid, manifest, base_dir)
                for iid in spine_list
            ]

        for payload in prepared:
            if payload is None:
                continue
            href = payload["href"]
            asset_path = payload["asset_path"]
            raw_content = payload["raw_content"]
            markup_with_markers = payload["markup_with_markers"]
            footnotes = payload["footnotes"]

            # Determine the hierarchical index for this spine file.
            # When the TOC has nested items, look up the file in the TOC index
            # map; fall back to a sequential orphan counter for files not in the
            # TOC (e.g. blank pages, dedication pages).
            if toc_index_map:
                chapter_idx: Any = toc_index_map.get(href) or toc_index_map.get(asset_path)
                if chapter_idx is None:
                    orphan_counter += 1
                    chapter_idx = orphan_counter
            else:
                chapter_idx = index_counter

            # Look up the TOC title for this file (used for naming derived splits).
            toc_chapter_title: Optional[str] = None
            if toc_title_map:
                toc_chapter_title = toc_title_map.get(asset_path) or toc_title_map.get(href)

            # --- Subchapter detection ---
            # Try to split the spine file at known CSS subchapter-title markers.
            sub_splits = self._split_html_on_subchapter_markers(
                markup_with_markers,
                chapter_idx,
                SUBCHAPTER_NUMBER_CLASSES,
                SUBCHAPTER_TITLE_CLASS,
            )
            # Fallback: detect numeric headings (e.g. <h3>1</h3>, <h3>2</h3>...).
            if sub_splits is None:
                sub_splits = self._split_html_on_numeric_headings(markup_with_markers, chapter_idx)

            if sub_splits:
                # Each CSS-marker fragment becomes an independent Chapter.
                for sec_num, (sub_index, sub_title, sub_html, has_explicit_title) in enumerate(
                    sub_splits, 1
                ):
                    # When the section has no dedicated title element (class_sG5),
                    # the title was derived from the first content paragraph.
                    # Prefix it with the parent chapter title and section number
                    # so that each file is identifiable without extra context.
                    if has_explicit_title:
                        chapter_name = sub_title
                    else:
                        if toc_chapter_title:
                            chapter_name = f"{toc_chapter_title} - {sec_num} - {sub_title}"
                        else:
                            chapter_name = f"{sec_num} - {sub_title}"

                    sub_text_fmt, sub_segments = TextProcessor.html_to_plain_text_with_formatting(
                        sub_html
                    )
                    if footnotes:
                        sub_text_fn = TextProcessor._render_footnotes(
                            sub_text_fmt,
                            footnotes,
                            mode="inline",
                            context_words=context_words,
                        )
                        sub_segments = TextProcessor._apply_footnotes_to_segments(
                            sub_segments,
                            footnotes,
                            mode="inline",
                            context_words=context_words,
                        )
                    else:
                        sub_text_fn = sub_text_fmt
                    sub_text = TextProcessor.add_pause_before_dash(sub_text_fn)
                    # Use only the parent TOC title (not the full chapter_name which
                    # includes the derived sub_title snippet) so that the first-sentence
                    # content is not double-spoken: once as a structural heading and
                    # again as the opening line of the section.
                    speech_title = toc_chapter_title or chapter_name
                    sub_speech = self._prepare_speech_text(
                        sub_text,
                        sub_segments,
                        raw_html=sub_html,
                        chapter_title=speech_title,
                    )

                    # A CSS sub-chapter can still be very long (e.g. a long
                    # chapter with no further heading markers).  Apply the same
                    # paragraph-boundary split so no single chapter exceeds the
                    # max size threshold.
                    if sub_text and len(sub_text) > self.paragraph_split_chars:
                        para_splits = self._split_text_at_paragraph_boundaries(
                            sub_text, self.paragraph_split_chars, sub_index
                        )
                        for p_idx, p_text in para_splits:
                            p_speech = self._prepare_speech_text(
                                p_text,
                                None,  # re-parse from fragment, not full-chapter segments
                                raw_html=sub_html,
                                chapter_title=speech_title,
                            )
                            chapters.append(
                                Chapter(
                                    index=p_idx,
                                    name=chapter_name,
                                    source_path=asset_path,
                                    text=p_text,
                                    raw_html=sub_html,
                                    formatting_segments=sub_segments,
                                    footnotes=list(footnotes) if footnotes else None,
                                    speech_text=p_speech or "",
                                )
                            )
                    else:
                        chapters.append(
                            Chapter(
                                index=sub_index,
                                name=chapter_name,
                                source_path=asset_path,
                                text=sub_text or "",
                                raw_html=sub_html,
                                formatting_segments=sub_segments,
                                footnotes=list(footnotes) if footnotes else None,
                                speech_text=sub_speech or "",
                            )
                        )
            else:
                # No CSS markers — process as a single chapter.
                text_with_formatting, formatting_segments = (
                    TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
                )
                if footnotes:
                    text_with_footnotes = TextProcessor._render_footnotes(
                        text_with_formatting,
                        footnotes,
                        mode="inline",
                        context_words=context_words,
                    )
                    formatting_segments = TextProcessor._apply_footnotes_to_segments(
                        formatting_segments,
                        footnotes,
                        mode="inline",
                        context_words=context_words,
                    )
                else:
                    text_with_footnotes = text_with_formatting
                text = TextProcessor.add_pause_before_dash(text_with_footnotes)
                raw_title = toc_chapter_title or (
                    TextProcessor.extract_title(raw_content, f"Chapter {chapter_idx}")
                    if text
                    else f"Chapter {chapter_idx}"
                )
                title = TextProcessor.clean_chapter_title(raw_title)

                # IMPORTANT: speech_text preserves [[lang:xx]] and [[fmt:...]] tags
                # while stripping only inline markdown (_italic_, **bold**, `code`).
                speech_text = self._prepare_speech_text(
                    text,
                    formatting_segments,
                    raw_html=raw_content,
                    chapter_title=title,
                )

                # --- Paragraph-boundary fallback split ---
                # When a chapter has no CSS subchapter markers but exceeds the
                # size threshold (computed from Edge concurrency / timeout),
                # split at paragraph boundaries to prevent Edge-TTS timeouts.
                if text and len(text) > self.paragraph_split_chars:
                    para_splits = self._split_text_at_paragraph_boundaries(
                        text, self.paragraph_split_chars, chapter_idx
                    )
                    for split_idx, split_text in para_splits:
                        split_speech = self._prepare_speech_text(
                            split_text,
                            None,  # re-parse from fragment, not full-chapter segments
                            raw_html=markup_with_markers,
                            chapter_title=title,
                        )
                        chapters.append(
                            Chapter(
                                index=split_idx,
                                name=title,
                                source_path=asset_path,
                                text=split_text,
                                raw_html=markup_with_markers,
                                formatting_segments=formatting_segments,
                                footnotes=list(footnotes) if footnotes else None,
                                speech_text=split_speech or "",
                            )
                        )
                else:
                    chapters.append(
                        Chapter(
                            index=chapter_idx,
                            name=title,
                            source_path=asset_path,
                            text=text or "",
                            raw_html=raw_content,
                            formatting_segments=formatting_segments,
                            footnotes=list(footnotes) if footnotes else None,
                            speech_text=speech_text or "",
                        )
                    )

            index_counter += 1

        return chapters

    def _remove_duplicate_chapters(self, chapters: List[Chapter]) -> List[Chapter]:
        """Remove chapters that have duplicate/overlapping content.

        This avoids creating separate entries for subchapters that repeat
        content already present in other chapters.
        """
        if not chapters:
            return chapters

        # Strategy: keep only chapters with unique content
        # For each chapter, extract "unique core" (content that doesn't appear in others)
        # Remove chapters whose content is 90%+ contained in other chapters

        # Step 1: normalize all texts
        normalized_texts = []
        for chapter in chapters:
            normalized_texts.append(self._normalize_for_comparison(chapter.text.strip()))

        # Step 2: identify chapters to remove
        chapters_to_keep = []
        removed_chapters = []

        for i, chapter in enumerate(chapters):
            current_norm = normalized_texts[i]

            # Empty or very short chapters: check if they're just dividers
            if len(current_norm) < 50:
                # Very short chapter, probably just a title
                removed_chapters.append(chapter)
                continue

            # Check if this chapter has unique significant content
            has_unique_content = True

            # Extract chapter "core" (first 500 chars after cleaning)
            core_content = current_norm[:500] if len(current_norm) > 500 else current_norm

            # Extract multiple text "windows" for comparison
            # Detects repeated content even with different prefixes
            windows = []
            window_size = 300
            step = 150  # Janelas sobrepostas
            for start in range(0, len(current_norm) - window_size, step):
                windows.append(current_norm[start : start + window_size])

            # Check if the core appears in other chapters (before or after)
            for j, other_chapter in enumerate(chapters):
                if i == j:
                    continue

                other_norm = normalized_texts[j]

                # If another chapter is larger and contains our core
                if len(other_norm) > len(current_norm) and core_content in other_norm:
                    # This chapter is a subset of a larger one
                    has_unique_content = False
                    break

                # Check if ANY significant text window appears in another chapter
                if len(other_norm) > len(current_norm):
                    for window in windows:
                        if len(window) >= 200 and window in other_norm:
                            # A significant portion of the text is repeated
                            has_unique_content = False
                            break
                    if not has_unique_content:
                        break

                # If another chapter is similar in size (±30%) and has high overlap
                if abs(len(other_norm) - len(current_norm)) < len(current_norm) * 0.3:
                    overlap = self._calculate_text_overlap(current_norm, other_norm)
                    if overlap > 0.6:  # 60% overlap
                        # Manter o que veio primeiro (ou o maior)
                        if j < i or len(other_norm) > len(current_norm):
                            has_unique_content = False
                            break

            if has_unique_content:
                chapters_to_keep.append(chapter)
            else:
                removed_chapters.append(chapter)

        # Integrity check: ensure no content was lost
        self._verify_content_integrity(chapters, chapters_to_keep, removed_chapters)

        return chapters_to_keep

    def _calculate_text_overlap(self, text1: str, text2: str) -> float:
        """Calculate overlap percentage between two texts using n-grams."""
        if not text1 or not text2:
            return 0.0

        # Use 3-grams (sequences of 3 words)
        words1 = text1.split()
        words2 = text2.split()

        if len(words1) < 3 or len(words2) < 3:
            # Textos muito curtos, comparar diretamente
            return 1.0 if text1 == text2 else 0.0

        # Criar conjuntos de 3-gramas
        ngrams1 = set()
        for i in range(len(words1) - 2):
            ngrams1.add(" ".join(words1[i : i + 3]))

        ngrams2 = set()
        for i in range(len(words2) - 2):
            ngrams2.add(" ".join(words2[i : i + 3]))

        if not ngrams1 or not ngrams2:
            return 0.0

        # Compute overlap (Jaccard similarity)
        intersection = ngrams1 & ngrams2
        union = ngrams1 | ngrams2

        return len(intersection) / len(union) if union else 0.0

    def _normalize_for_comparison(self, text: str) -> str:
        """Normalise text for comparison by removing markup and formatting."""
        if not text:
            return ""

        # Remove Markdown markup
        cleaned = re.sub(r"\*+", "", text)  # Remove asteriscos
        cleaned = re.sub(r"_+", "", cleaned)  # Remove underscores
        cleaned = re.sub(r"\[\[.*?\]\]", "", cleaned)  # Remove marcadores [[...]]
        cleaned = re.sub(r"§\s*\d+", "", cleaned)  # Remove sections §1, §2, etc.

        # Normalize whitespace
        cleaned = " ".join(cleaned.split())

        # Remove common leading punctuation
        cleaned = cleaned.lstrip(" .-:")

        return cleaned.lower()

    def _verify_content_integrity(
        self,
        original_chapters: List[Chapter],
        filtered_chapters: List[Chapter],
        removed_chapters: List[Chapter],
    ) -> None:
        """Verify that all original content is present after filtering.

        Compares total content to ensure no text was lost.
        """
        # Extract all unique words from the original (normalized to ignore formatting)
        original_words = set()
        for chapter in original_chapters:
            normalized = self._normalize_for_comparison(chapter.text.strip())
            words = normalized.split()
            # Filter out very short words (likely markup)
            words = [w for w in words if len(w) > 2]
            original_words.update(words)

        # Extract all unique words from filtered chapters
        filtered_words = set()
        for chapter in filtered_chapters:
            normalized = self._normalize_for_comparison(chapter.text.strip())
            words = normalized.split()
            words = [w for w in words if len(w) > 2]
            filtered_words.update(words)

        # Check for missing words
        missing_words = original_words - filtered_words

        # Filter out words that are only markup or isolated numbers
        significant_missing = set()
        for word in missing_words:
            # Ignore pure numbers, very short words, or markup
            if word.isdigit() or len(word) <= 3:
                continue
            # Ignorar palavras com muitos caracteres especiais
            alpha_ratio = sum(1 for c in word if c.isalpha()) / len(word) if word else 0
            if alpha_ratio < 0.5:
                continue
            significant_missing.add(word)

        if significant_missing:
            # Significant content is missing — this is a problem.
            missing_sample = list(significant_missing)[:20]
            print("⚠️ WARNING: Possibly lost content detected during duplicate filtering!")
            print(f"   Palavras faltando (amostra): {' '.join(missing_sample)}")
            print(f"   Total unique words missing: {len(significant_missing)}")

            # Identify which removed chapters had unique content
            for removed in removed_chapters:
                removed_normalized = self._normalize_for_comparison(removed.text.strip())
                removed_words = set(w for w in removed_normalized.split() if len(w) > 3)
                removed_unique = removed_words - filtered_words
                # Filter out markup
                removed_unique = set(
                    w
                    for w in removed_unique
                    if w and len(w) > 0 and sum(1 for c in w if c.isalpha()) / len(w) >= 0.5
                )
                if removed_unique:
                    print(
                        f"   ❌ Capítulo '{removed.name}' tinha {len(removed_unique)} palavras únicas perdidas"
                    )

            # Restore removed chapters that had unique content
            # Do NOT do this automatically — only warn
            raise ValueError(
                f"Integrity check failed: {len(significant_missing)} unique words lost. "
                "The duplicate removal algorithm needs adjustment."
            )

    def _parse_toc(
        self,
        archive: zipfile.ZipFile,
        base_dir: str,
        *,
        opf_path: Optional[str] = None,
    ) -> List[TocItem]:
        """Parse the table of contents, trying NCX (EPUB2) then nav.xhtml (EPUB3)."""
        cached = _toc_cache_get(self.file_path, opf_path)
        if cached is not None:
            return cached
        # --- EPUB2: NCX ---
        candidates = [name for name in archive.namelist() if name.lower().endswith(".ncx")]
        if candidates:
            try:
                raw = self._read_zip_text(archive, candidates[0])
                tree = ET.fromstring(raw)
                nav_map = tree.find("ncx:navMap", XML_NS)
                if nav_map is not None:

                    def build(entries, level=1):
                        items = []
                        for nav_point in entries:
                            label_elem = nav_point.find("ncx:navLabel/ncx:text", XML_NS)
                            content_elem = nav_point.find("ncx:content", XML_NS)
                            title = (
                                label_elem.text.strip()
                                if label_elem is not None and label_elem.text
                                else ""
                            )
                            href = (
                                content_elem.attrib.get("src", "")
                                if content_elem is not None
                                else ""
                            )
                            children_points = nav_point.findall("ncx:navPoint", XML_NS)
                            items.append(
                                TocItem(
                                    title=title,
                                    href=href,
                                    level=level,
                                    children=build(children_points, level + 1),
                                )
                            )
                        return items

                    top_level_points = nav_map.findall("ncx:navPoint", XML_NS)
                    built = build(top_level_points, level=1)
                    _toc_cache_put(self.file_path, opf_path, built)
                    return built
            except (ET.ParseError, KeyError):
                pass

        # --- EPUB3: nav.xhtml (fallback) ---
        if opf_path:
            nav_items = self._parse_nav_toc_from_opf(archive, opf_path, base_dir)
            if nav_items:
                _toc_cache_put(self.file_path, opf_path, nav_items)
                return nav_items

        _toc_cache_put(self.file_path, opf_path, [])
        return []

    @staticmethod
    def _parse_nav_toc_from_opf(
        archive: zipfile.ZipFile,
        opf_path: str,
        base_dir: str,
    ) -> List[TocItem]:
        """Locate and parse the EPUB3 nav document declared in the OPF manifest."""
        try:
            opf_content = EpubParser._read_zip_text(archive, opf_path)
            opf_tree = ET.fromstring(opf_content)
        except Exception:
            return []

        nav_href: Optional[str] = None
        for item in opf_tree.findall("opf:manifest/opf:item", XML_NS):
            props = item.attrib.get("properties", "")
            if "nav" in props.lower().split():
                nav_href = item.attrib.get("href", "") or None
                break

        if not nav_href:
            return []

        nav_path = EpubParser._join_path(base_dir, nav_href)
        try:
            nav_content = EpubParser._read_zip_text(archive, nav_path)
        except (KeyError, Exception):
            return []

        return EpubParser._parse_nav_html(nav_content)

    @staticmethod
    def _parse_nav_html(nav_content: str) -> List[TocItem]:
        """Parse an EPUB3 nav.xhtml document and return a TocItem hierarchy."""
        EPUB_NS_URI = "http://www.idpf.org/2007/ops"

        # Strip DOCTYPE which ElementTree cannot handle
        cleaned = re.sub(r"<!DOCTYPE[^>]*>", "", nav_content, count=1)
        try:
            root = ET.fromstring(cleaned)
        except ET.ParseError:
            return []

        def _tag_local(elem) -> str:
            tag = elem.tag
            return tag.split("}", 1)[-1] if "}" in tag else tag

        def _find_toc_nav(node) -> Optional[ET.Element]:
            """Find <nav epub:type="toc"> anywhere in the tree."""
            if _tag_local(node) == "nav":
                epub_type = (
                    node.attrib.get(f"{{{EPUB_NS_URI}}}type") or node.attrib.get("epub:type") or ""
                )
                if "toc" in epub_type.lower():
                    return node
            for child in node:
                found = _find_toc_nav(child)
                if found is not None:
                    return found
            return None

        toc_nav = _find_toc_nav(root)
        if toc_nav is None:
            return []

        def parse_ol(ol_elem, level: int) -> List[TocItem]:
            items: List[TocItem] = []
            for child in ol_elem:
                if _tag_local(child) != "li":
                    continue
                href = ""
                title = ""
                children: List[TocItem] = []
                for sub in child:
                    local = _tag_local(sub)
                    if local == "a":
                        href = sub.attrib.get("href", "")
                        title = "".join(sub.itertext()).strip()
                    elif local == "span":
                        # Some nav docs use <span> instead of <a> for headings
                        if not title:
                            title = "".join(sub.itertext()).strip()
                    elif local == "ol":
                        children = parse_ol(sub, level + 1)
                if href or title:
                    items.append(TocItem(title=title, href=href, level=level, children=children))
            return items

        for child in toc_nav:
            if _tag_local(child) == "ol":
                return parse_ol(child, level=1)

        return []

    @staticmethod
    def _build_toc_level_map(toc: List[TocItem]) -> Dict[str, int]:
        """Return a map from file path (anchor stripped) to its minimum TOC level.

        When the same file appears at multiple levels (e.g. a split file referenced
        at L1 with one anchor and at L2 with another anchor), the *minimum* (highest
        in the hierarchy) level wins.
        """
        level_map: Dict[str, int] = {}

        def walk(items: List[TocItem]) -> None:
            for item in items:
                href = item.href
                if href:
                    file_path = href.split("#")[0] if "#" in href else href
                    if file_path:
                        prev = level_map.get(file_path)
                        level_map[file_path] = (
                            min(prev, item.level) if prev is not None else item.level
                        )
                walk(item.children)

        walk(toc)
        return level_map

    def _build_toc_title_map(self, toc: List[TocItem], base_dir: str) -> Dict[str, str]:
        title_map: Dict[str, str] = {}

        def walk(items: List[TocItem]) -> None:
            for item in items:
                href = item.href.split("#")[0] if item.href else ""
                if href and item.title:
                    asset_path = self._join_path(base_dir, href)
                    title_map.setdefault(asset_path, item.title.strip())
                    title_map.setdefault(href, item.title.strip())
                walk(item.children)

        walk(toc)
        return title_map

    def _assign_levels_from_toc(
        self,
        chapters: List[Chapter],
        toc: List[TocItem],
        base_dir: str,
    ) -> None:
        """Set chapter.level for every chapter based on its position in the TOC.

        Chapters whose source file is not found in the TOC keep their default
        level (1).  When a file is referenced at multiple TOC depths (e.g. an
        anchor-split file) the shallowest (lowest numeric) level is used.
        """
        if not toc:
            return
        level_map = self._build_toc_level_map(toc)
        if not level_map:
            return

        # Pre-compute normalised keys once to avoid repeated work.
        # TOC hrefs are relative to the OPF dir (base_dir); chapter source_paths
        # are stored as full archive paths (base_dir/relative).
        def _relative(source_path: str) -> str:
            """Strip base_dir prefix so the key matches TOC hrefs."""
            prefix = base_dir.rstrip("/") + "/"
            if source_path.startswith(prefix):
                return source_path[len(prefix) :]
            return source_path

        for chapter in chapters:
            src = chapter.source_path
            # Strip any trailing anchor from the source_path (rare, but safe)
            src_file = src.split("#")[0] if "#" in src else src
            rel = _relative(src_file)

            level = level_map.get(rel)
            if level is None:
                # Basename-only fallback (handles books where base_dir is unknown)
                basename = rel.split("/")[-1] if "/" in rel else rel
                level = level_map.get(basename)

            if level is not None:
                chapter.level = level

    @staticmethod
    def _opf_dir(opf_path: str) -> str:
        return str(Path(opf_path).parent).replace("\\", "/") if "/" in opf_path else ""

    @staticmethod
    def _join_path(base_dir: str, href: str) -> str:
        if href.startswith("/"):
            path = href.lstrip("/")
        else:
            href = href.lstrip("/")
            if not base_dir:
                path = href
            else:
                path = f"{base_dir.rstrip('/')}/{href}"
        return posixpath.normpath(unquote(path))

    @staticmethod
    def _is_html_like(href: str) -> bool:
        return href.lower().endswith((".xhtml", ".html", ".htm", ".xml"))

    @staticmethod
    def _read_zip_text(archive: zipfile.ZipFile, member: str) -> str:
        try:
            data = archive.read(member)
        except KeyError:
            data = archive.read(unquote(member))
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data.decode("latin-1", errors="ignore")


class PdfParser:
    """Very small PDF parser that extracts each page as a chapter."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = str(file_path)
        self.path = Path(file_path)

    def parse(self) -> Book:
        if not PDF_AVAILABLE:
            raise ImportError("pypdf library not installed")

        with open(self.file_path, "rb") as handle:  # pragma: no cover - exercised in tests
            reader = pypdf.PdfReader(handle)  # type: ignore[arg-type]

            metadata = reader.metadata or {}
            title = metadata.get("/Title") or metadata.get("Title") or self.path.stem
            author = metadata.get("/Author") or metadata.get("Author") or ""

            chapters: List[Chapter] = []
            for idx, page in enumerate(reader.pages, start=1):
                try:
                    raw_text = page.extract_text() or ""
                except Exception:
                    chapters.append(
                        Chapter(
                            index=idx,
                            name=f"Página {idx} (erro)",
                            source_path=f"page_{idx}",
                            text="",
                        )
                    )
                    continue

                # First join broken lines, then normalize whitespace
                joined_text = TextProcessor.join_broken_lines(raw_text)
                cleaned = TextProcessor.normalise_whitespace(joined_text)
                if not cleaned:
                    continue
                cleaned = TextProcessor.add_pause_before_dash(cleaned)
                chapters.append(
                    Chapter(
                        index=idx, name=f"Página {idx}", source_path=f"page_{idx}", text=cleaned
                    )
                )

        return Book(title=str(title), author=str(author), chapters=chapters)


class EbookReader:
    """Facade used by the rest of the code base."""

    def __init__(
        self,
        file_path: Optional[str | Path] = None,
        paragraph_split_chars: int = 0,
    ) -> None:
        self.file_path: Optional[Path] = None
        self.book: Optional[Book] = None
        self._paragraph_split_chars = paragraph_split_chars
        if file_path is not None:
            self.file_path = Path(file_path)
            self.load(file_path, paragraph_split_chars=paragraph_split_chars)

    def load(
        self,
        file_path: str | Path,
        paragraph_split_chars: Optional[int] = None,
    ) -> None:
        path = Path(file_path)
        if not path.exists():
            raise FileNotFoundError(f"File not found: {path}")

        suffix = path.suffix.lower()
        if suffix not in {".epub", ".pdf"}:
            raise ValueError(f"Unsupported format: {suffix}")

        ps_chars = (
            paragraph_split_chars
            if paragraph_split_chars is not None
            else self._paragraph_split_chars
        )
        self._paragraph_split_chars = ps_chars
        self.file_path = path
        if suffix == ".epub":
            self.book = EpubParser(str(path), paragraph_split_chars=ps_chars).parse()
        else:
            self.book = PdfParser(str(path)).parse()

    @property
    def title(self) -> str:
        return self.book.title if self.book else ""

    @property
    def author(self) -> str:
        return self.book.author if self.book else ""

    @property
    def language(self) -> Optional[str]:
        """Get the language code from EPUB metadata (e.g., 'en', 'pt')."""
        return self.book.language if self.book else None

    def get_chapters(self) -> List[Chapter]:
        return list(self.book.chapters) if self.book else []

    def _ensure_loaded(self) -> Optional[Book]:
        if not self.book:
            if not self.file_path:
                raise RuntimeError("Reader has no file loaded")
            self.load(self.file_path)
        return self.book

    def get_chapter_structure(self, preserve_all: bool = True) -> List[Chapter]:
        chapters = self.get_chapters()
        if preserve_all:
            return chapters
        return [chapter for chapter in chapters if len(chapter.text.strip()) >= 100]

    def read_ebook(self, file_path: str | Path) -> Tuple[str, str, List[Tuple[str, str]]]:
        self.load(file_path)
        if not self.book:
            return "", "", []
        chapters = [(chapter.name, chapter.text) for chapter in self.book.chapters]
        return self.book.title, self.book.author, chapters

    def get_toc(self) -> List[TocItem]:
        book = self._ensure_loaded()
        if not book:
            return []
        return list(book.toc)

    def extract_cover_image(self) -> Optional[CoverImage]:
        """Return the raw cover image bundled in the EPUB or PDF, if available."""
        if not self.file_path:
            return None

        suffix = self.file_path.suffix.lower()

        # EPUB cover extraction
        if suffix == ".epub":
            try:
                parser = EpubParser(str(self.file_path))
                with zipfile.ZipFile(self.file_path, "r") as archive:
                    opf_path = parser._find_opf_path(archive)
                    opf_dir = parser._opf_dir(opf_path)
                    opf_content = parser._read_zip_text(archive, opf_path)
                    opf_tree = ET.fromstring(opf_content)

                    manifest: Dict[str, Dict[str, str]] = {}
                    for item in opf_tree.findall("opf:manifest/opf:item", XML_NS):
                        item_id = item.attrib.get("id")
                        href = item.attrib.get("href")
                        if not item_id or not href:
                            continue
                        manifest[item_id] = {
                            "href": href,
                            "media_type": item.attrib.get("media-type", ""),
                            "properties": item.attrib.get("properties", ""),
                        }

                    cover_entry = self._detect_cover_entry(opf_tree, manifest)
                    if not cover_entry:
                        return None

                    cover_href = cover_entry.get("href")
                    if not cover_href:
                        return None

                    cover_path = parser._join_path(opf_dir, cover_href)
                    try:
                        data = archive.read(cover_path)
                    except KeyError:
                        data = archive.read(unquote(cover_path))

                    media_type = cover_entry.get("media_type") or "image/jpeg"
                    if not media_type or media_type == "image/jpeg":
                        if mimetypes is not None:
                            media_type = mimetypes.guess_type(cover_href)[0] or "image/jpeg"
                    extension = Path(cover_path).suffix
                    if not extension:
                        if mimetypes is not None:
                            extension = mimetypes.guess_extension(media_type) or ".jpg"
                        else:
                            extension = ".jpg"
                    if not extension.startswith("."):
                        extension = f".{extension}"
                    return CoverImage(data=data, media_type=media_type, extension=extension)
            except Exception:
                return None

        # PDF cover extraction
        elif suffix == ".pdf":
            return self._extract_pdf_cover()

        return None

    def extract_chapter_resources(self, chapter: Chapter) -> list[dict[str, str]]:
        """Return bounded image resources referenced by an EPUB chapter."""
        if not self.file_path or self.file_path.suffix.lower() != ".epub":
            return []
        raw_html = (chapter.raw_html or "").strip()
        source_path = (chapter.source_path or "").split("#", 1)[0].strip()
        if not raw_html or not source_path:
            return []
        refs = re.findall(r"<img\b[^>]*\bsrc\s*=\s*['\"]([^'\"]+)['\"]", raw_html, re.I)
        if not refs:
            return []
        try:
            parser = EpubParser(str(self.file_path))
            with zipfile.ZipFile(self.file_path, "r") as archive:
                opf_dir = parser._opf_dir(parser._find_opf_path(archive))
                chapter_asset = parser._join_path(opf_dir, source_path)
                chapter_dir = posixpath.dirname(chapter_asset)
                resources: list[dict[str, str]] = []
                for href in refs[:32]:
                    if href.lower().startswith(("data:", "http:", "https:")):
                        continue
                    asset_path = parser._join_path(
                        chapter_dir, unquote(href.split("#", 1)[0].split("?", 1)[0])
                    )
                    try:
                        data = archive.read(asset_path)
                    except KeyError:
                        continue
                    if not data or len(data) > 12 * 1024 * 1024:
                        continue
                    media_type = mimetypes.guess_type(asset_path)[0] if mimetypes else None
                    if not media_type or not media_type.startswith("image/"):
                        continue
                    resources.append(
                        {
                            "href": href,
                            "mediaType": media_type,
                            "dataBase64": base64.b64encode(data).decode("ascii"),
                        }
                    )
                return resources
        except Exception:
            return []

    def extract_chapter_stylesheet(self, chapter: Chapter) -> str:
        """Return the concatenated CSS referenced by a chapter XHTML file."""
        if not self.file_path or self.file_path.suffix.lower() != ".epub":
            return ""
        raw_html = (chapter.raw_html or "").strip()
        source_path = (chapter.source_path or "").split("#", 1)[0].strip()
        if not raw_html or not source_path:
            return ""

        hrefs: list[str] = []
        for tag_match in re.finditer(r"<link\b[^>]*>", raw_html, re.IGNORECASE):
            attributes = dict(
                re.findall(
                    r"([:\w-]+)\s*=\s*[\"']([^\"']*)[\"']",
                    tag_match.group(0),
                    re.IGNORECASE,
                )
            )
            rel_tokens = attributes.get("rel", "").lower().split()
            href = attributes.get("href", "").strip()
            if "stylesheet" in rel_tokens and "alternate" not in rel_tokens and href:
                hrefs.append(href)
        if not hrefs:
            return ""

        parser = EpubParser(str(self.file_path))
        css_parts: List[str] = []

        try:
            with zipfile.ZipFile(self.file_path, "r") as archive:
                opf_path = parser._find_opf_path(archive)
                opf_dir = parser._opf_dir(opf_path)
                chapter_asset = parser._join_path(opf_dir, source_path)
                chapter_dir = posixpath.dirname(chapter_asset)

                seen_paths: set[str] = set()
                for href in hrefs:
                    stylesheet_path = parser._join_path(chapter_dir, href)
                    if stylesheet_path in seen_paths:
                        continue
                    seen_paths.add(stylesheet_path)
                    try:
                        css_parts.append(parser._read_zip_text(archive, stylesheet_path))
                    except Exception:
                        continue
        except Exception:
            return ""

        return "\n\n".join(part for part in css_parts if part.strip())

    def _extract_pdf_cover(self) -> Optional[CoverImage]:
        """Extract cover image from PDF's first page."""
        if not PDF_AVAILABLE or not pypdf:
            return None

        try:
            # Open PDF and get first page
            with open(self.file_path, "rb") as handle:
                reader = pypdf.PdfReader(handle)  # type: ignore[arg-type]
                if not reader.pages:
                    return None

                first_page = reader.pages[0]

                # Try to extract images from first page
                if hasattr(first_page, "images"):
                    # pypdf >= 3.1.0 has images property
                    images = first_page.images
                    if images:
                        # Get the largest image (likely the cover)
                        largest_image = max(
                            images, key=lambda img: len(img.data) if hasattr(img, "data") else 0
                        )
                        if hasattr(largest_image, "data") and largest_image.data:
                            # Determine media type and extension
                            image_name = getattr(largest_image, "name", "") or ""
                            extension = Path(image_name).suffix if image_name else ""

                            # Try to detect image format from data
                            data = largest_image.data
                            if data.startswith(b"\xff\xd8\xff"):
                                media_type = "image/jpeg"
                                extension = extension or ".jpg"
                            elif data.startswith(b"\x89PNG\r\n\x1a\n"):
                                media_type = "image/png"
                                extension = extension or ".png"
                            elif data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
                                media_type = "image/gif"
                                extension = extension or ".gif"
                            else:
                                media_type = "image/jpeg"
                                extension = extension or ".jpg"

                            if not extension.startswith("."):
                                extension = f".{extension}"

                            return CoverImage(data=data, media_type=media_type, extension=extension)

                # Fallback: Try XObject images (older pypdf versions or complex PDFs)
                if "/Resources" in first_page and "/XObject" in first_page["/Resources"]:
                    xobject = first_page["/Resources"]["/XObject"]
                    if hasattr(xobject, "get_object"):
                        xobject = xobject.get_object()

                    # Find largest image
                    largest_data = None
                    largest_size = 0
                    image_filter = None

                    for obj_name in xobject:
                        obj = xobject[obj_name]
                        if hasattr(obj, "get_object"):
                            obj = obj.get_object()

                        if obj.get("/Subtype") == "/Image":
                            try:
                                data = obj.get_data()
                                if len(data) > largest_size:
                                    largest_size = len(data)
                                    largest_data = data
                                    image_filter = obj.get("/Filter", "")
                            except Exception:
                                continue

                    if largest_data:
                        # Determine format from filter
                        if "DCTDecode" in str(image_filter):
                            media_type = "image/jpeg"
                            extension = ".jpg"
                        elif "FlateDecode" in str(image_filter):
                            media_type = "image/png"
                            extension = ".png"
                        else:
                            # Try to detect from data
                            if largest_data.startswith(b"\xff\xd8\xff"):
                                media_type = "image/jpeg"
                                extension = ".jpg"
                            elif largest_data.startswith(b"\x89PNG\r\n\x1a\n"):
                                media_type = "image/png"
                                extension = ".png"
                            else:
                                media_type = "image/jpeg"
                                extension = ".jpg"

                        return CoverImage(
                            data=largest_data, media_type=media_type, extension=extension
                        )

        except Exception:
            return None

        return None

    def _detect_cover_entry(
        self,
        opf_tree: ET.Element,
        manifest: Dict[str, Dict[str, str]],
    ) -> Optional[Dict[str, str]]:
        metadata = opf_tree.find("opf:metadata", XML_NS)
        cover_id = None
        if metadata is not None:
            meta_cover = metadata.find("opf:meta[@name='cover']", XML_NS)
            if meta_cover is None:
                for meta in metadata.findall(".//*"):
                    tag = meta.tag.split("}", 1)[-1]
                    if tag.lower() == "meta" and meta.attrib.get("name") == "cover":
                        meta_cover = meta
                        break
            if meta_cover is not None:
                cover_id = meta_cover.attrib.get("content")
        if cover_id and cover_id in manifest:
            return manifest[cover_id]

        for item_id, entry in manifest.items():
            props = (entry.get("properties") or "").lower()
            href = entry.get("href") or ""
            media_type = (entry.get("media_type") or "").lower()
            if "cover-image" in props:
                return entry
            if item_id.lower() in {"cover", "cover-image"}:
                return entry
            if media_type.startswith("image/") and "cover" in href.lower():
                return entry
        return None


def read_book(file_path: str | Path) -> Book:
    reader = EbookReader(file_path)
    if not reader.book:
        raise RuntimeError("Failed to read book")
    return reader.book


def parse_epub_to_dict(file_path: str, book_id: str = "") -> dict:
    """iOS-friendly serialisation of a parsed Book.

    Returns a plain dict whose shape matches the wire contract of
    ``GET /api/jobs/{id}/fulltext`` (see ``EbookFulltext.swift``), so the
    SwiftUI client can ``JSONDecoder().decode(EbookFulltext.self, ...)``
    the result with no adapter layer.

    Used by the in-process Python embed on iOS (``PythonBridge.swift``)
    to share the canonical parser with the macOS sidecar and HF Spaces
    backend instead of maintaining a parallel Swift implementation
    (``LocalEpubParser.swift``, removed).

    Drops zero-length chapters; ``charCount`` reflects only ``text``.
    ``html`` / ``css`` / ``segments`` are emitted as ``None`` (iOS
    decoder treats them as optional) because the on-device parse path
    does not preserve raw HTML/CSS today.
    """
    book = read_book(file_path)
    chapters: list[dict] = []
    out_index = 1
    for chapter in book.chapters:
        text = (chapter.text or "").strip()
        if not text:
            continue
        chapters.append(
            {
                "index": out_index,
                "name": chapter.name,
                "text": text,
                "html": None,
                "css": None,
                "charCount": len(text),
                "segments": None,
            }
        )
        out_index += 1
    return {
        "jobId": book_id,
        "bookTitle": book.title,
        "bookAuthor": book.author,
        "chapters": chapters,
    }


__all__ = ["EbookReader", "read_book", "parse_epub_to_dict", "Book", "Chapter"]
