# -*- coding: utf-8 -*-
"""HTML filtering and plain-text extraction."""

from __future__ import annotations

from typing import List, Optional, Tuple

from .text_formatting import FormattingSegment


class HtmlTextExtraction:
    """HTML filtering and plain-text extraction."""

    @staticmethod
    def strip_html_tags(content: Optional[str]) -> str:
        from . import ebook_reader as _runtime
        if not content:
            return ""

        class _TagStripper(_runtime.HTMLParser):
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
        from . import ebook_reader as _runtime
        if not content:
            return ""

        class _IgnoredBlockStripper(_runtime.HTMLParser):
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
                    f' {name}="{_runtime.html.escape(value, quote=True)}"'
                    if value is not None
                    else f" {name}"
                    for name, value in attrs
                )
                self.parts.append(f"<{tag}{attrs_text}>")

            def handle_startendtag(self, tag: str, attrs: list[tuple[str, Optional[str]]]) -> None:
                if tag in {"style", "script", "head", "title"} or self._ignored_stack:
                    return
                attrs_text = "".join(
                    f' {name}="{_runtime.html.escape(value, quote=True)}"'
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
        from . import ebook_reader as _runtime
        if not title:
            return title
        cleaned = _runtime.TextProcessor.normalise_whitespace(title)
        cleaned = _runtime.re.sub(r"^(?:part\d{3,})(?:\s*[-–:]\s*|\s+)", "", cleaned, flags=_runtime.re.IGNORECASE)
        cleaned = cleaned.strip()
        return cleaned or title.strip()

    @staticmethod
    def html_to_plain_text_with_formatting(
        content: Optional[str],
    ) -> Tuple[str, List[FormattingSegment]]:
        """Convert HTML to plain text while preserving formatting information"""
        from . import ebook_reader as _runtime
        if not content:
            return "", []

        # Initialize formatting processor
        formatter = _runtime.TextFormattingProcessor()
        cleaned_content = _runtime.TextProcessor.strip_ignored_html_blocks(content)

        # Extract formatting and convert to internal markers
        text_with_markers = formatter.extract_formatting(cleaned_content)

        # Apply standard text processing
        text = str(text_with_markers)
        text = _runtime.NBSP_RE.sub(" ", text)
        text = _runtime.ARTIFACT_RE.sub(" ", text)
        text = text.replace("\r", "\n")
        # HTML treats raw newlines inside elements as whitespace. Collapse them
        # before block-element processing so only actual block boundaries (<p>,
        # <div>, <br>, etc.) become newlines — not source-level line wraps.
        text = _runtime.re.sub(r"\n+", " ", text)
        text = _runtime.PARA_BLOCK_RE.sub("\n", text)

        # Clean remaining HTML tags but preserve formatting markers
        text = _runtime.re.sub(
            r"<(?!/?fmt)[^>]+>", "", text
        )  # Remove HTML tags but keep [[fmt:...]] markers
        text = _runtime.WHITESPACE_RE.sub(" ", text)
        text = _runtime.re.sub(r"\n{3,}", "\n\n", text)

        lines = [line.strip() for line in text.split("\n")]
        lines = [line for line in lines if line]
        clean_text = "\n".join(lines)

        # Parse the text with formatting markers into segments
        formatting_segments = formatter.parse_formatted_text(clean_text)

        # Render inline emphasis markers back into the text
        formatted_text = formatter.apply_inline_formatting(clean_text)
        formatted_text = _runtime.re.sub(r"[ \t]{2,}", " ", formatted_text)
        formatted_text = _runtime.re.sub(r"\s*\n\s*", "\n", formatted_text)
        formatted_text = formatted_text.strip()

        return formatted_text, formatting_segments

    @staticmethod
    def html_to_plain_text(content: Optional[str]) -> str:
        from . import ebook_reader as _runtime
        if not content:
            return ""

        text = _runtime.TextProcessor.strip_ignored_html_blocks(str(content))

        # Preserve dialog structure - add extra newline before dialog markers
        text = _runtime.re.sub(r"([.!?])\s*([—–-]\s*)", r"\1\n\2", text)

        # Convert common entities and special chars
        text = _runtime.NBSP_RE.sub(" ", text)
        text = text.replace("&mdash;", "—")
        text = text.replace("&ndash;", "–")
        text = text.replace("&ldquo;", '"')
        text = text.replace("&rdquo;", '"')
        text = text.replace("&lsquo;", "'")
        text = text.replace("&rsquo;", "'")
        text = text.replace("&hellip;", "…")

        # Clean artifacts but preserve important separators
        text = _runtime.ARTIFACT_RE.sub(" ", text)
        text = text.replace("\r", "\n")

        # Convert block-level tags to newlines (preserve paragraph structure)
        text = _runtime.PARA_BLOCK_RE.sub("\n", text)

        # Remove remaining HTML tags
        text = _runtime.TextProcessor.strip_html_tags(text)

        # Normalize whitespace within lines but preserve paragraph breaks
        text = _runtime.WHITESPACE_RE.sub(" ", text)

        # Preserve double newlines (paragraph breaks) but remove excessive ones
        text = _runtime.re.sub(r"\n{4,}", "\n\n\n", text)  # Max 3 newlines for section breaks

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
