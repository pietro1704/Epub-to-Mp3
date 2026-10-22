# -*- coding: utf-8 -*-
"""Text cleanup and structural speech announcements."""

from __future__ import annotations

import re

from typing import List, Optional


class StructuralSpeechPreparation:
    """Text cleanup and structural speech announcements."""

    @staticmethod
    def html_to_text(content: str) -> str:
        from . import ebook_reader as _runtime
        if not content:
            return ""
        text = _runtime.TextProcessor.strip_ignored_html_blocks(str(content))
        text = _runtime.NBSP_RE.sub(" ", text)
        text = _runtime.ARTIFACT_RE.sub(" ", text)
        text = _runtime.PARA_BLOCK_RE.sub("\n", text)
        text = _runtime.TextProcessor.strip_html_tags(text)
        text = _runtime.PAGE_BREAK_RE.sub("\n", text)
        text = _runtime.WHITESPACE_RE.sub(" ", text)
        text = _runtime.re.sub(r"\n{2,}", "\n", text)
        return text.strip()

    @staticmethod
    def add_pause_before_dash(text: str) -> str:
        from . import ebook_reader as _runtime
        if not text:
            return ""

        def insert_break(match: re.Match) -> str:
            preceding = match.group(1)
            dash = match.group(2)
            trailing = match.group(3)
            return f"{preceding}\n{dash}{trailing}"

        pattern = _runtime.re.compile(r"([^\s\n])\s*(—)(\s*)")
        updated = pattern.sub(insert_break, text)
        return updated

    @staticmethod
    def extract_title(markup: str, fallback: str) -> str:
        from . import ebook_reader as _runtime
        match = _runtime.H_TAG.search(markup)
        if match:
            heading = _runtime.TextProcessor.strip_html_tags(match.group(2)).strip()
            if heading:
                return heading
        # Fallback to the first meaningful words of the content
        text = _runtime.TextProcessor.html_to_text(markup)
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
        from . import ebook_reader as _runtime
        return _runtime.WHITESPACE_RE.sub(" ", text.strip())

    @staticmethod
    def join_broken_lines(text: str) -> str:
        """Join lines broken in the middle of sentences (typical in PDFs).

        Preserves real paragraph breaks (lines ending with punctuation).
        Removes repeated headers/footers that appear on multiple pages.
        """
        from . import ebook_reader as _runtime
        if not text:
            return ""

        lines = text.split("\n")

        # First: detect and remove repeated headers/footers
        lines = _runtime.TextProcessor._remove_pdf_headers_footers(lines)

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
        from . import ebook_reader as _runtime
        if not content:
            return None
        match = _runtime.H_TAG.search(content)
        if not match:
            return None
        heading = _runtime.TextProcessor.strip_html_tags(match.group(2))
        return _runtime.TextProcessor.normalise_whitespace(heading)

    @staticmethod
    def extract_structural_titles(
        content: Optional[str], chapter_title: Optional[str] = None
    ) -> List[str]:
        from . import ebook_reader as _runtime
        titles: List[str] = []
        seen: set[str] = set()

        _p_tag = _runtime.re.compile(r"<p\b[^>]*>(.*?)</p>", _runtime.re.I | _runtime.re.DOTALL)

        def _add(raw: str) -> None:
            norm = _runtime.TextProcessor.normalise_whitespace(
                _runtime.NBSP_RE.sub(" ", _runtime.TextProcessor.strip_html_tags(raw))
            )
            key = norm.casefold()
            if norm and key not in seen:
                seen.add(key)
                titles.append(norm)

        if content:
            for match in _runtime.H_TAG.finditer(content):
                _add(match.group(2))

            # Scan <p> elements for structural titles (subtitles, author attributions,
            # section labels) that look like headings: ≤ 8 words, no terminal punctuation.
            # When h tags exist, stop at the first paragraph that looks like body text
            # (long or ends with sentence punctuation) — this captures attribution lines
            # such as "DE BRUNO TOLENTINO" after an "PREFÁCIO" h1.
            # When no h tags are present, preserve the original behaviour: scan all
            # <p> elements up to the 6-title limit (e.g. pt-BR IT edition).
            _has_h_tags = _runtime.H_TAG.search(content) is not None
            for p_match in _p_tag.finditer(content):
                raw = _runtime.TextProcessor.strip_html_tags(p_match.group(1)).strip()
                norm = _runtime.TextProcessor.normalise_whitespace(_runtime.NBSP_RE.sub(" ", raw))
                if norm and len(norm.split()) <= 8 and norm[-1] not in ".!?":
                    _add(p_match.group(1))
                elif _has_h_tags:
                    # First body-like paragraph signals end of the opening block.
                    break
                if len(titles) >= 6:
                    break

        if chapter_title:
            normalised = _runtime.TextProcessor.clean_chapter_title(chapter_title)
            _add(normalised)
            # Also add each segment split on em-dash / colon separators so that
            # EPUBs using <p> for headings (e.g. pt-BR editions) still get
            # individual heading lines recognised as title keys.
            # Example: "Capítulo 3 – Seis telefonemas (1985)" → ["Capítulo 3",
            #           "Seis telefonemas (1985)"]
            for part in _runtime.re.split(r"\s*[–—:]\s*", normalised):
                part = part.strip()
                if part and len(part) > 3:
                    _add(part)

        return titles

    @staticmethod
    def _first_nonempty_line(text: str) -> str:
        from . import ebook_reader as _runtime
        for line in text.split("\n"):
            normalised = _runtime.TextProcessor.normalise_whitespace(line)
            if normalised:
                return normalised
        return ""

    @staticmethod
    def _first_nonempty_lines(text: str, limit: int = 2) -> List[str]:
        from . import ebook_reader as _runtime
        lines: List[str] = []
        for line in text.split("\n"):
            normalised = _runtime.TextProcessor.normalise_whitespace(line)
            if normalised:
                lines.append(normalised)
                if len(lines) >= limit:
                    break
        return lines

    @staticmethod
    def _structural_key(text: str) -> str:
        from . import ebook_reader as _runtime
        compact = text.casefold()
        compact = _runtime.re.sub(r"[^\w\s]", " ", compact)
        return _runtime.re.sub(r"\s+", " ", compact).strip()

    @staticmethod
    def apply_structural_speech_cues(
        text: str,
        raw_html: Optional[str] = None,
        chapter_title: Optional[str] = None,
    ) -> str:
        from . import ebook_reader as _runtime
        if not text:
            return ""

        updated = text
        titles = _runtime.TextProcessor.extract_structural_titles(raw_html, chapter_title)
        if not titles:
            return updated

        first_line = _runtime.TextProcessor._first_nonempty_line(updated)
        opening_preview = " ".join(_runtime.TextProcessor._first_nonempty_lines(updated, limit=4))
        toc_title = _runtime.TextProcessor.clean_chapter_title(chapter_title or "")
        first_line_key = _runtime.TextProcessor._structural_key(first_line)
        opening_key = _runtime.TextProcessor._structural_key(opening_preview)
        toc_title_key = _runtime.TextProcessor._structural_key(toc_title)
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
            stripped = _runtime.TextProcessor.normalise_whitespace(line)
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
        result = _runtime.re.sub(
            r"(^|\n)\s*(\d+)\s*\|\s*[.!?]?\s*(\n|$)",
            lambda m: f"{m.group(1)}{m.group(3)}",
            result,
        )
        result = _runtime.re.sub(
            r"(^|\n)\s*##+\s*(\d{1,3})\s*[.!?]?\s*(\n|$)",
            lambda m: f"{m.group(1)}{m.group(3)}",
            result,
        )
        result = _runtime.re.sub(
            r"(^|\n)(\d{1,3})\s*\n(\s*\S)",
            lambda m: f"{m.group(1)}{m.group(3)}",
            result,
        )

        return result

    @staticmethod
    def extract_title_from_text(text: Optional[str], max_words: int = 6) -> str:
        from . import ebook_reader as _runtime
        if not text:
            return ""
        cleaned = str(text).replace("\r", " ").replace("\n", " ").replace("\f", " ")
        cleaned = cleaned.replace("\t", " ")
        cleaned = _runtime.TextProcessor.normalise_whitespace(cleaned)
        if not cleaned:
            return ""
        words = cleaned.split()
        if len(words) <= max_words:
            return " ".join(words)
        return " ".join(words[:max_words])
