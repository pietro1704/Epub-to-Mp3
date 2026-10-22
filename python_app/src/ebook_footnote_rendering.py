# -*- coding: utf-8 -*-
"""Footnote fallback, rendering and speech context."""

from __future__ import annotations

import re

from typing import Dict, List, Optional, Tuple

from .text_formatting import FormattingSegment


class FootnoteRendering:
    """Footnote fallback, rendering and speech context."""

    @staticmethod
    def inject_footnotes(
        markup: Optional[str],
        mode: str = "inline",
        context_words: int = 8,
        external_file_resolver=None,
    ) -> tuple[str, List[Dict[str, str]]]:
        from . import ebook_reader as _runtime
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
                    _runtime.hashlib.blake2b(
                        str(markup).encode("utf-8", errors="ignore"), digest_size=20
                    ).hexdigest()
                    if _runtime.hashlib is not None
                    else None
                )
            except Exception:
                cache_key = None
            if cache_key is not None:
                with _runtime.TextProcessor._footnote_cache_lock:
                    hit = _runtime.TextProcessor._footnote_cache.get(cache_key)
                if hit is not None:
                    # Defensive copy of the footnote list so callers can
                    # mutate it without poisoning the cache.
                    return hit[0], [dict(fn) for fn in hit[1]]

        try:
            from bs4 import BeautifulSoup  # type: ignore
        except ImportError:  # pragma: no cover - optional dependency
            BeautifulSoup = None

        if BeautifulSoup is not None:
            processed_markup, footnotes = _runtime.TextProcessor._collect_footnotes_bs4(
                str(markup), BeautifulSoup, external_file_resolver
            )
        else:
            processed_markup, footnotes = _runtime.TextProcessor._collect_footnotes_fallback(str(markup))

        if cache_key is not None:
            with _runtime.TextProcessor._footnote_cache_lock:
                if len(_runtime.TextProcessor._footnote_cache) >= _runtime.TextProcessor._FOOTNOTE_CACHE_LIMIT:
                    drop = max(1, _runtime.TextProcessor._FOOTNOTE_CACHE_LIMIT // 10)
                    for old in list(_runtime.TextProcessor._footnote_cache.keys())[:drop]:
                        _runtime.TextProcessor._footnote_cache.pop(old, None)
                _runtime.TextProcessor._footnote_cache[cache_key] = (
                    processed_markup,
                    [dict(fn) for fn in footnotes],
                )

        return processed_markup, footnotes

    @staticmethod
    def _collect_footnotes_fallback(markup: str) -> Tuple[str, List[Dict[str, str]]]:
        from . import ebook_reader as _runtime
        anchor_pattern = _runtime.re.compile(
            r'(<sup[^>]*>\s*)?<a[^>]+href=["\"][^"#\']*#(?P<fragment>[^"\']+)["\"][^>]*>(?P<label>.*?)</a>(\s*</sup>)?',
            _runtime.re.IGNORECASE | _runtime.re.DOTALL,
        )

        referenced_fragments: set[str] = set()
        referenced_fragments_lower: set[str] = set()
        for match in anchor_pattern.finditer(markup):
            fragment = match.group("fragment")
            if not fragment:
                continue
            referenced_fragments.add(fragment)
            referenced_fragments_lower.add(fragment.lower())

        footnote_pattern = _runtime.re.compile(
            r'<(?P<tag>div|p|section|aside|li)[^>]*id="(?P<id>[^"]+)"[^>]*>(?P<body>.*?)</(?P=tag)>',
            _runtime.re.IGNORECASE | _runtime.re.DOTALL,
        )
        footnote_map: Dict[str, str] = {}

        def looks_like_footnote_id(foot_id: str) -> bool:
            if not foot_id:
                return False
            lowered = foot_id.lower()
            if lowered in referenced_fragments_lower or foot_id in referenced_fragments:
                return True
            if _runtime.re.search(r"(foot|note|rodape|rodapé)", lowered):
                return True
            if _runtime.re.match(r"(?:fn|n|nota|rodape|rodapé)[\w\-]*\d*$", lowered):
                return True
            return False

        def capture(match: re.Match) -> str:
            foot_id = match.group("id")
            if not looks_like_footnote_id(foot_id):
                return match.group(0)
            body = match.group("body")
            plain = _runtime.TextProcessor.html_to_plain_text(body)
            cleaned = _runtime.TextProcessor.normalise_whitespace(plain)
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
            label = _runtime.TextProcessor.html_to_plain_text(match.group("label"))
            label_digits = "".join(ch for ch in label if ch.isdigit())
            is_superscript = bool(match.group(1))
            fragment_hint = bool(
                _runtime.re.search(r"(foot|fn|note|rodape|rodapé)\w*", fragment_key, _runtime.re.IGNORECASE)
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
                    "text": _runtime.TextProcessor.normalise_whitespace(footnote_text),
                    "original_text": _runtime.TextProcessor.normalise_whitespace(
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
        from . import ebook_reader as _runtime
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
                idx = text.find(marker)
                if idx == -1:
                    continue
                # Guard: if the marker appears before the first newline it is
                # embedded inside the chapter heading (e.g. <h1>Title *</h1>).
                # Placing the note verbatim there would prefix the entire chapter
                # body with footnote text, corrupting the MP3 title.  Instead,
                # strip the marker from the heading and re-insert the note after
                # the first paragraph break so the heading remains clean.
                first_nl = text.find("\n")
                if first_nl == -1 or idx < first_nl:
                    # Marker is inside the chapter heading.  Placing the note
                    # there would prefix the entire body with footnote text.
                    # Instead, remove the marker from the heading and append the
                    # note at the END of the chapter so the prose is read first.
                    text_without_marker = text[:idx] + text[idx + len(marker) :]
                    text = text_without_marker.rstrip() + replacement
                else:
                    text = text[:idx] + replacement + text[idx + len(marker) :]
            return text

        appended_entries: List[Tuple[str, str, str]] = []
        for footnote in footnotes:
            marker = footnote["marker"]
            while marker in text:
                idx = text.find(marker)
                if idx == -1:
                    break
                preceding = text[:idx]
                snippet = _runtime.TextProcessor._extract_context_snippet(preceding, context_words)
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
