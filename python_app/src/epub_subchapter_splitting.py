# -*- coding: utf-8 -*-
"""EPUB subchapter boundaries and spine preparation."""

from __future__ import annotations

import threading
import zipfile
from typing import Any, Dict, List, Optional, Tuple


class EpubSubchapterSplitting:
    """EPUB subchapter boundaries and spine preparation."""

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
        from . import ebook_reader as _runtime
        if not markup or not number_classes or not title_class:
            return None

        num_alt = "|".join(_runtime.re.escape(c) for c in sorted(number_classes))
        number_re = _runtime.re.compile(
            r'<p\b[^>]+\bclass="[^"]*(?:' + num_alt + r')[^"]*"[^>]*>.*?</p>',
            _runtime.re.IGNORECASE | _runtime.re.DOTALL,
        )
        title_re = _runtime.re.compile(
            r'<p\b[^>]*\bclass="[^"]*' + _runtime.re.escape(title_class) + r'[^"]*"[^>]*>(.*?)</p>',
            _runtime.re.IGNORECASE | _runtime.re.DOTALL,
        )
        any_p_re = _runtime.re.compile(r"<p\b[^>]*>(.*?)</p>", _runtime.re.IGNORECASE | _runtime.re.DOTALL)

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
                raw = _runtime.TextProcessor.strip_html_tags(tm.group(1)).strip()
                split_points.append((nm.start(), raw or f"Section {len(split_points) + 1}", True))
            else:
                # No dedicated title element — derive title from first paragraph content.
                fallback_window = markup[window_start : window_start + 2000]
                any_p = any_p_re.search(fallback_window)
                if any_p:
                    raw = _runtime.TextProcessor.strip_html_tags(any_p.group(1)).strip()
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
        from . import ebook_reader as _runtime
        tag_alt = "|".join(_runtime.re.escape(t) for t in heading_tags)
        heading_re = _runtime.re.compile(
            r"<(" + tag_alt + r")\b[^>]*>(.*?)</\1>",
            _runtime.re.IGNORECASE | _runtime.re.DOTALL,
        )
        any_p_re = _runtime.re.compile(r"<p\b[^>]*>(.*?)</p>", _runtime.re.IGNORECASE | _runtime.re.DOTALL)

        num_matches: List[Tuple[int, str]] = []
        for m in heading_re.finditer(markup):
            text = _runtime.TextProcessor.strip_html_tags(m.group(2)).strip()
            if _runtime.re.fullmatch(r"\d+", text):
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
                raw = _runtime.TextProcessor.strip_html_tags(any_p.group(1)).strip()
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
        from . import ebook_reader as _runtime
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
                _runtime.EpubParser._force_split_long_line(line, max_chars)
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
        from . import ebook_reader as _runtime
        href = manifest.get(item_id)
        if not href or not self._is_html_like(href):
            return None
        asset_path = self._join_path(base_dir, href)
        try:
            with archive_lock:
                raw_content = self._read_zip_text(archive, asset_path)
        except KeyError:
            return None
        if _runtime.TextProcessor.looks_like_css(raw_content):
            return None

        # Skip files that are explicitly marked as footnote/endnote containers
        # using EPUB3 ARIA roles or epub:type semantics.  These are end-note
        # sections (e.g. Hobbit_note_N.xhtml) that publishers include in the
        # spine for reflowable reading order but never intend to be spoken as
        # independent chapters.  Detection is structural (role attribute), not
        # filename-based, so it generalises across publishers.
        if _runtime._is_endnote_container(raw_content):
            import logging as _logging

            _logging.getLogger(__name__).debug("Skipping endnote container: %s", asset_path)
            return None

        chapter_dir = str(_runtime.Path(asset_path).parent).replace("\\", "/") if "/" in asset_path else ""

        def resolve_external_file(relative_path: str) -> Optional[str]:
            try:
                full_path = self._join_path(chapter_dir, relative_path)
                with archive_lock:
                    return self._read_zip_text(archive, full_path)
            except (KeyError, Exception):
                return None

        markup_with_markers, footnotes = _runtime.TextProcessor.inject_footnotes(
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
