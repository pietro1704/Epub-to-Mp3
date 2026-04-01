# -*- coding: utf-8 -*-
"""
Text formatting detection and markup system for audio differentiation
"""

import os
import re
from dataclasses import dataclass
from typing import List, Optional, Sequence


@dataclass
class FormattingSegment:
    """Text segment with specific formatting"""

    text: str
    formatting: str  # 'normal', 'italic', 'bold', 'emphasis', 'strong', etc.
    language: Optional[str] = None


PRESERVE_TTS_LAYOUT = os.getenv("PRESERVE_TTS_LAYOUT", "1").lower() in ("1", "true", "yes")


class TextFormattingProcessor:
    """Text formatting processor for audio differentiation"""

    FORMAT_MARKER_RE = re.compile(r"\[\[fmt:[^\]]+\]\]|\[\[/fmt\]\]", re.IGNORECASE)

    # Pre-compiled regexes for strip_inline_markdown (performance optimization)
    _BOLD_ASTERISK_RE = re.compile(r"\*\*\s*(.+?)\s*\*\*", re.DOTALL)
    _BOLD_UNDERSCORE_RE = re.compile(r"__\s*(.+?)\s*__", re.DOTALL)
    _ITALIC_UNDERSCORE_RE = re.compile(r"_\s*([^_]+?)\s*_")
    _CODE_RE = re.compile(r"`([^`]+?)`")
    _LOOSE_ASTERISKS_RE = re.compile(r"\*+")
    _LOOSE_UNDERSCORES_RE = re.compile(r"_+")
    _MULTI_SPACES_RE = re.compile(r"[ \t]{2,}")
    _MULTI_NEWLINES_RE = re.compile(r"\n{3,}")

    def process_markup_tags(self, text: str) -> str:
        """Process markup tags from LanguageMarkup into formatting markers"""
        if not text:
            return text

        # Convert emphasis tags to formatting markers
        text = re.sub(
            r"\[\[emphasis:mild\]\](.*?)\[\[/emphasis\]\]", r"[[fmt:italic]]\1[[/fmt]]", text
        )
        text = re.sub(
            r"\[\[emphasis:strong\]\](.*?)\[\[/emphasis\]\]", r"[[fmt:bold]]\1[[/fmt]]", text
        )

        # Convert pause tags to SSML pauses (keep as-is for now)
        text = re.sub(r"\[\[pause:short\]\]", '<break time="300ms"/>', text)
        text = re.sub(r"\[\[pause:medium\]\]", '<break time="600ms"/>', text)
        text = re.sub(r"\[\[pause:long\]\]", '<break time="1s"/>', text)

        # Convert tone tags to prosody
        text = re.sub(r"\[\[tone:lower\]\](.*?)\[\[/tone\]\]", r"[[fmt:lower]]\1[[/fmt]]", text)

        return text

    # Common HTML/EPUB formatting patterns
    FORMATTING_PATTERNS = {
        "italic": [
            r"<i\b[^>]*>(.*?)</i>",
            r"<em\b[^>]*>(.*?)</em>",
            r"<cite\b[^>]*>(.*?)</cite>",
        ],
        "bold": [
            r"<b\b[^>]*>(.*?)</b>",
            r"<strong\b[^>]*>(.*?)</strong>",
        ],
        "emphasis": [
            r"<emphasis\b[^>]*>(.*?)</emphasis>",
        ],
        "code": [
            r"<code\b[^>]*>(.*?)</code>",
            r"<tt\b[^>]*>(.*?)</tt>",
        ],
        "quote": [
            r"<blockquote\b[^>]*>(.*?)</blockquote>",
            r"<q\b[^>]*>(.*?)</q>",
        ],
        "small": [
            r"<small\b[^>]*>(.*?)</small>",
            r"<sub\b[^>]*>(.*?)</sub>",
            r"<sup\b[^>]*>(.*?)</sup>",
        ],
    }

    # Internal markers to preserve formatting
    INTERNAL_MARKERS = {
        "italic": "[[fmt:italic]]{}[[/fmt]]",
        "bold": "[[fmt:bold]]{}[[/fmt]]",
        "emphasis": "[[fmt:emphasis]]{}[[/fmt]]",
        "code": "[[fmt:code]]{}[[/fmt]]",
        "quote": "[[fmt:quote]]{}[[/fmt]]",
        "small": "[[fmt:small]]{}[[/fmt]]",
    }

    INLINE_RENDERERS = {
        "italic": lambda value: f"_{value}_",
        "bold": lambda value: f"**{value}**",
        "emphasis": lambda value: f"_{value}_",
        "code": lambda value: f"`{value}`",
        "quote": lambda value: f"“{value}”",
        "small": lambda value: value,
        "lower": lambda value: value,
    }

    DEFAULT_CUE_LOCALE = "pt"

    CUE_LABELS = {
        "pt": {
            "italic": ("em itálico:", "fim do itálico."),
            "bold": ("em negrito:", "fim do negrito."),
            "emphasis": ("diálogo:", "fim do diálogo."),
            "code": ("trecho de código:", "fim do código."),
            "quote": ("entre aspas:", "fim das aspas."),
            "small": ("texto pequeno:", "fim do texto pequeno."),
        },
        "en": {
            "italic": ("italic text:", "end italic."),
            "bold": ("bold text:", "end bold."),
            "emphasis": ("dialogue:", "end dialogue."),
            "code": ("code snippet:", "end code."),
            "quote": ("quote:", "end quote."),
            "small": ("small text:", "end small text."),
        },
    }

    FOOTNOTE_END_PHRASES = (
        "fim da nota de rodapé",
        "fim da nota de rodape",
        "end of footnote",
        "end footnote",
    )

    def __init__(self, *, cues_enabled: bool = True, cue_locale: str = DEFAULT_CUE_LOCALE):
        self.compiled_patterns = {}
        self.cues_enabled = bool(cues_enabled)
        locale_root = (cue_locale or self.DEFAULT_CUE_LOCALE).split("-", 1)[0].lower()
        if locale_root not in self.CUE_LABELS:
            locale_root = "en"
        self.cue_locale = locale_root
        for fmt_type, patterns in self.FORMATTING_PATTERNS.items():
            self.compiled_patterns[fmt_type] = [
                re.compile(pattern, re.IGNORECASE | re.DOTALL) for pattern in patterns
            ]

    def extract_formatting(self, html_text: str) -> str:
        """Extract HTML formatting and convert to internal markers."""
        if not html_text:
            return html_text

        # First process markup tags from LanguageMarkup
        text = self.process_markup_tags(html_text)

        # **NEW**: Extract lang attributes and convert to [[lang:xx]]
        text = self._extract_language_attributes(text)

        # Process each formatting type
        for fmt_type, patterns in self.compiled_patterns.items():
            marker_template = self.INTERNAL_MARKERS[fmt_type]

            for pattern in patterns:

                def replace_with_marker(match):
                    content = match.group(1)
                    # Remove inner HTML tags but preserve content
                    clean_content = re.sub(r"<[^>]+>", "", content)
                    return marker_template.format(clean_content)

                text = pattern.sub(replace_with_marker, text)

        # Add markers for inline quotes and dialogue dashes
        text = self._add_inline_emphasis_markers(text)

        return text

    def parse_formatted_text(self, text: str) -> List[FormattingSegment]:
        """Parse text with internal markers into formatting segments."""
        if not text:
            return []

        segments = []

        # Pattern to find internal markers
        marker_pattern = re.compile(r"\[\[fmt:(\w+)\]\](.*?)\[\[/fmt\]\]", re.DOTALL)

        last_end = 0

        for match in marker_pattern.finditer(text):
            start, end = match.span()

            # Add normal text before marker
            if start > last_end:
                normal_text = text[last_end:start].strip()
                if normal_text:
                    segments.append(FormattingSegment(normal_text, "normal"))

            # Add formatted text
            fmt_type = match.group(1)
            fmt_text = match.group(2).strip()
            if fmt_text:
                segments.append(FormattingSegment(fmt_text, fmt_type))

            last_end = end

        # Add remaining text
        if last_end < len(text):
            remaining_text = text[last_end:].strip()
            if remaining_text:
                segments.append(FormattingSegment(remaining_text, "normal"))

        # No formatting: return full text as normal
        if not segments and text.strip():
            segments.append(FormattingSegment(text.strip(), "normal"))

        return segments

    def to_edge_ssml(
        self, segments: List[FormattingSegment], voice: str = "pt-BR-ThalitaMultilingualNeural"
    ) -> str:
        """Converte segmentos formatados para SSML do Edge TTS"""
        if not segments:
            return ""

        ssml_parts = [
            '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
            'xmlns:mstts="http://www.w3.org/2001/mstts">'
        ]

        for segment in segments:
            text = self._escape_ssml(segment.text)

            if segment.formatting == "italic":
                # Italic: higher pitch, slower and lower volume to stand out
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody rate="-20%" pitch="+15%" volume="-5%">{text}</prosody>'
                    f"</voice>"
                )
            elif segment.formatting == "bold":
                # Negrito: mais forte e um pouco mais lento
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody volume="+20%" rate="-5%">{text}</prosody>'
                    f"</voice>"
                )
            elif segment.formatting == "emphasis":
                # Emphasis: pause before and after, different pitch
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<break time="200ms"/>'
                    f'<prosody rate="-15%" pitch="+10%">{text}</prosody>'
                    f'<break time="200ms"/>'
                    f"</voice>"
                )
            elif segment.formatting == "code":
                # Code: more monotone and slower
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<break time="100ms"/>'
                    f'<prosody rate="-30%" pitch="-5%">{text}</prosody>'
                    f'<break time="100ms"/>'
                    f"</voice>"
                )
            elif segment.formatting == "quote":
                # Quote: pause and different pitch
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<break time="300ms"/>'
                    f'<prosody rate="-10%" pitch="-10%">{text}</prosody>'
                    f'<break time="300ms"/>'
                    f"</voice>"
                )
            elif segment.formatting == "small":
                # Small text: faster and quieter
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody rate="+10%" volume="-10%">{text}</prosody>'
                    f"</voice>"
                )
            elif segment.formatting == "lower":
                # Lower pitch (for parentheses)
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody pitch="-15%" volume="-5%">{text}</prosody>'
                    f"</voice>"
                )
            else:  # normal
                ssml_parts.append(f'<voice name="{voice}">{text}</voice>')

        ssml_parts.append("</speak>")
        return "".join(ssml_parts)

    def _get_cue_phrases(self, fmt_type: str) -> tuple[str, str]:
        locale_map = self.CUE_LABELS.get(self.cue_locale) or self.CUE_LABELS["en"]
        fallback_map = self.CUE_LABELS["en"]
        return locale_map.get(fmt_type) or fallback_map.get(fmt_type, ("", ""))

    @staticmethod
    def _render_with_cues(start: str, text: str, end: str) -> str:
        parts = []
        if start:
            parts.append(start.strip())
        parts.append(text.strip())
        if end:
            parts.append(end.strip())
        return " ".join(part for part in parts if part)

    def to_plain_text_with_cues(self, segments: List[FormattingSegment]) -> str:
        """Convert to plain text with verbal formatting cues."""
        if not segments:
            return ""

        if not self.cues_enabled:
            return " ".join(segment.text for segment in segments if segment.text)

        parts = []

        for segment in segments:
            text = segment.text

            if segment.formatting in {"italic", "bold", "emphasis", "code", "quote", "small"}:
                start, end = self._get_cue_phrases(segment.formatting)
                formatted = self._render_with_cues(start, text, end)
                parts.append(formatted)
            else:  # normal
                parts.append(text)

        return " ".join(parts)

    def to_plain_text_with_pauses(self, segments: List[FormattingSegment]) -> str:
        """Convert to plain text with pauses to indicate formatting."""
        if not segments:
            return ""

        parts = []

        for segment in segments:
            text = segment.text

            if segment.formatting in ["italic", "emphasis"]:
                parts.append(f"... {text} ...")
            elif segment.formatting == "bold":
                parts.append(f"-- {text} --")
            elif segment.formatting == "quote":
                parts.append(f'"" {text} ""')
            else:  # normal, code, small
                parts.append(text)

        return " ".join(parts)

    def apply_inline_formatting(self, text: str) -> str:
        """Replace internal markers with inline emphasis tokens."""
        if not text:
            return ""

        marker_pattern = re.compile(r"\[\[fmt:(\w+)\]\](.*?)\[\[/fmt\]\]", re.DOTALL)

        def replace(match: re.Match) -> str:
            fmt_type = match.group(1)
            content = match.group(2)
            renderer = self.INLINE_RENDERERS.get(fmt_type)
            if renderer:
                rendered = renderer(content)
                return rendered
            return content

        formatted = marker_pattern.sub(replace, text)
        return formatted

    @classmethod
    def remove_formatting_markers(cls, text: str) -> str:
        """
        Remove [[fmt:...]] markers while preserving inner content.

        Preserves original spaces and line breaks.
        """
        if not text:
            return ""

        return cls.FORMAT_MARKER_RE.sub("", text)

    @classmethod
    def strip_inline_markdown(cls, text: str) -> str:
        """Strip Markdown markers from text (optimized with pre-compiled regexes)."""
        if not text:
            return ""

        # Remove [[fmt:...]] markers
        cleaned = cls.remove_formatting_markers(text)

        # Remove Markdown using pre-compiled regexes
        cleaned = cls._BOLD_ASTERISK_RE.sub(r"\1", cleaned)  # **texto**
        cleaned = cls._BOLD_UNDERSCORE_RE.sub(r"\1", cleaned)  # __texto__
        cleaned = cls._ITALIC_UNDERSCORE_RE.sub(r"\1", cleaned)  # _texto_
        cleaned = cls._CODE_RE.sub(r"\1", cleaned)  # `code`

        # Limpar asteriscos e underscores soltos
        cleaned = cls._LOOSE_ASTERISKS_RE.sub("", cleaned)
        cleaned = cls._LOOSE_UNDERSCORES_RE.sub("", cleaned)

        # Normalize whitespace
        cleaned = cls._MULTI_SPACES_RE.sub(" ", cleaned)
        cleaned = cls._MULTI_NEWLINES_RE.sub("\n\n", cleaned)

        return cleaned.strip()

    @classmethod
    def remove_isolated_section_numbers(cls, text: str) -> str:
        """
        Remove isolated section numbers that cause long TTS pauses.

        Example:
        "1.\nSome text here\n2.\nMore text"
        → "Some text here\nMore text"

        Isolated section numbers (like "1.", "2.", etc. on their own lines)
        cause extremely long pauses in Edge-TTS, increasing audio duration
        by over 100%. This function removes them automatically.
        """
        if not text:
            return ""

        # Remove lines containing only a number followed by a period (section markers)
        # Pattern: line start, optional spaces, digits, period, optional spaces, line end
        lines = text.split("\n")
        cleaned_lines = []

        for line in lines:
            # If the line is just a number followed by a period, skip it
            if re.match(r"^\s*\d+\.\s*$", line):
                continue
            cleaned_lines.append(line)

        return "\n".join(cleaned_lines)

    @classmethod
    def consolidate_short_lines(cls, text: str, max_line_length: int = 80) -> str:
        """
        Consolidate consecutive short lines to avoid excessive TTS pauses.

        Edge-TTS inserts long pauses between lines, especially short lines.
        This function joins consecutive short lines into longer paragraphs,
        drastically reducing audio duration.

        Example:
        "Short line 1.\\nShort line 2.\\nShort line 3.\\n\\nNew section."
        → "Short line 1. Short line 2. Short line 3.\\n\\nNew section."

        Preserves:
        - Double line breaks (section/paragraph changes)
        - Dialogue lines starting with an em dash
        - Long lines (>max_line_length)
        """
        if not text:
            return ""

        # Split on double line breaks to preserve sections
        sections = re.split(r"\n\n+", text)
        consolidated_sections = []

        for section in sections:
            if not section.strip():
                continue

            lines = section.split("\n")
            consolidated_lines = []
            buffer = []

            for line in lines:
                line = line.strip()
                if not line:
                    continue

                # If the line starts with a dash (dialogue), handle separately
                is_dialogue = line.startswith("—") or line.startswith("-")

                # If the line is long OR is dialogue, flush buffer and add the line
                if len(line) > max_line_length or is_dialogue:
                    if buffer:
                        consolidated_lines.append(" ".join(buffer))
                        buffer = []
                    consolidated_lines.append(line)
                else:
                    # Short line — add to buffer
                    buffer.append(line)

            # Flush remaining buffer
            if buffer:
                consolidated_lines.append(" ".join(buffer))

            # Junta as linhas consolidadas
            if consolidated_lines:
                consolidated_sections.append("\n".join(consolidated_lines))

        # Join sections with double line break
        return "\n\n".join(consolidated_sections)

    @classmethod
    def apply_prosody_for_short_sentences(cls, text: str, rate_increase: str = "+20%") -> str:
        """
        Apply SSML prosody tags to speed up audio when text has many short sentences.

        Edge-TTS inserts long pauses between short sentences, drastically increasing
        audio duration. This function detects when text has a high density
        of punctuation (many short sentences) and applies a speech rate increase
        to compensate for the excessive pauses.

        Args:
            text: Text to process
            rate_increase: Percentage speech rate increase (e.g. "+20%", "+50%")

        Returns:
            Text with SSML prosody tags applied if necessary
        """
        if not text:
            return ""

        # Calculate short-sentence density (sentences per 1000 chars)
        # Sentence-ending punctuation: . ! ?
        sentence_endings = text.count(".") + text.count("!") + text.count("?")
        text_length = len(text)

        if text_length == 0:
            return text

        # Density: how many sentences per 1000 chars
        sentence_density = (sentence_endings / text_length) * 1000

        # If density > 10 sentences/1000 chars, apply prosody
        # Edge-TTS inserts long pauses even at moderate density (10-15)
        # Chapters with heavy dialogue/short narrative may have 15-30+
        if sentence_density > 10:
            # Apply prosody rate to speed up the audio
            # Compensates for long Edge-TTS pauses between sentences
            return f'<prosody rate="{rate_increase}">{text}</prosody>'

        return text

    @classmethod
    def clean_tts_text(cls, text: str, apply_prosody: bool = False) -> str:
        """
        Remove internal markers and markdown, preserving language hints.

        Args:
            text: Text to process
            apply_prosody: DEPRECATED — prosody is now applied per-chunk in the TTS engine
        """
        if not text:
            return ""

        # Preserve layout faithfully — only strip internal markers
        return cls.remove_formatting_markers(text)

    @classmethod
    def enhance_natural_pauses(cls, text: str) -> str:
        """
        Enhance text with natural pauses for better listening experience.

        Adds appropriate pauses after:
        - Dialog markers (em-dash, quotes)
        - Section transitions
        - Important punctuation

        Args:
            text: Text to process

        Returns:
            Text with enhanced natural pauses
        """
        if not text:
            return ""

        # Add pause after chapter/section numbers for separation
        text = re.sub(r"(Capítulo\s+\d+[.:]\s*[^\n]{1,50}?)\n", r"\1.\n", text, flags=re.IGNORECASE)
        text = re.sub(r"(Chapter\s+\d+[.:]\s*[^\n]{1,50}?)\n", r"\1.\n", text, flags=re.IGNORECASE)

        # Enhance paragraph breaks with proper punctuation
        # If paragraph ends without punctuation, add period
        text = re.sub(r"([^\n.!?])\n\n", r"\1.\n\n", text)
        text = cls._append_pause_after_line_breaks(text)

        # Add comma after introductory phrases (more conservative)
        # Only for common Portuguese/English discourse markers, not simple words
        introductory_phrases = r"(Então|Agora|Assim|Portanto|Entretanto|Contudo|Todavia|However|Therefore|Thus|Meanwhile|Moreover|Furthermore)"
        text = re.sub(
            rf"^{introductory_phrases}\s+([a-z])",
            r"\1, \2",
            text,
            flags=re.MULTILINE | re.IGNORECASE,
        )

        # Ensure proper spacing around ellipsis for natural pauses.
        # Use [ \t]* (not \s*) so newlines are preserved — otherwise heading
        # lines ending with "...\n" get collapsed onto one line.
        text = re.sub(r"\.{3,}", "...", text)
        text = re.sub(r"[ \t]*\.\.\.[ \t]*", "... ", text)

        return text

    def to_audible_text(
        self,
        text: str,
        formatting_segments: Optional[List[FormattingSegment]] = None,
    ) -> str:
        """
        Convert text to a TTS-ready version with audible cues.
        """
        if not text and not formatting_segments:
            return ""

        segments = formatting_segments or self.parse_formatted_text(text)

        if not segments:
            return self.clean_tts_text(text)

        audible = self.to_plain_text_with_cues(segments)
        audible = self._inject_pause_markers(audible)
        return self.clean_tts_text(audible)

    def _inject_pause_markers(self, text: str) -> str:
        if not text:
            return ""
        if PRESERVE_TTS_LAYOUT:
            return text

        end_cues = self._collect_end_cues()
        text = self._append_pause_after_phrases(text, end_cues, pause_token=".")
        text = self._append_pause_after_phrases(text, self.FOOTNOTE_END_PHRASES, pause_token="...")
        text = self._append_pause_after_line_breaks(text)
        return text

    def _collect_end_cues(self) -> List[str]:
        cues: set[str] = set()
        locale_map = self.CUE_LABELS.get(self.cue_locale) or self.CUE_LABELS["en"]
        fallback_map = self.CUE_LABELS["en"]
        for _, end in locale_map.values():
            if end:
                cues.add(end)
        for _, end in fallback_map.values():
            if end:
                cues.add(end)
        return sorted(cues)

    @staticmethod
    def _append_pause_after_phrases(text: str, phrases: Sequence[str], *, pause_token: str) -> str:
        if not text or not phrases:
            return text

        escaped = [re.escape(phrase) for phrase in phrases if phrase]
        if not escaped:
            return text

        pattern = re.compile(r"(?i)\b(" + "|".join(escaped) + r")\b(?!\s*[.!?,;:\)\]\}])")
        return pattern.sub(rf"\1{pause_token} ", text)

    @staticmethod
    def _append_pause_after_line_breaks(text: str) -> str:
        if not text:
            return ""

        def replace(match: re.Match) -> str:
            last_char = match.group(1)
            breaks = match.group(2)
            if last_char in ".!?;:":
                return f"{last_char}{breaks}"
            pause = "..." if breaks.count("\n") > 1 else "."
            return f"{last_char}{pause}{breaks}"

        return re.sub(r"([^\s\n])([ \t]*\n+)", replace, text)

    def _add_inline_emphasis_markers(self, text: str) -> str:
        """
        Add emphasis markers for common audiobook patterns:
        - "Texto entre aspas duplas" → [[fmt:quote]]..[[/fmt]]
        - —Dialogue with em dash → [[fmt:emphasis]]..[[/fmt]]

        IMPORTANT: Do not add markers for already-processed markdown (_italic_, **bold**)
        """
        if not text:
            return text

        # Detect text enclosed in double quotes (curly or straight)
        # Skip if already has a [[fmt:...]] marker
        quote_pattern = re.compile(r'(?<!\[\[fmt:)"([^"]{10,}?)"(?!\]\])', re.UNICODE)

        def add_quote_marker(match):
            content = match.group(1)
            # Skip if already has an internal marker
            if "[[fmt:" in content:
                return match.group(0)
            return f"[[fmt:quote]]{content}[[/fmt]]"

        text = quote_pattern.sub(add_quote_marker, text)

        # Detect dialogue dash (— or --) at the start of a paragraph/line
        # Add emphasis to distinguish narration from dialogue
        dash_pattern = re.compile(r"^(—|--)\s*(.+?)$", re.MULTILINE)

        def add_dash_emphasis(match):
            dash = match.group(1)
            content = match.group(2)
            # Skip if already has a marker
            if "[[fmt:" in content:
                return match.group(0)
            return f"{dash} [[fmt:emphasis]]{content}[[/fmt]]"

        text = dash_pattern.sub(add_dash_emphasis, text)

        return text

    def _escape_ssml(self, text: str) -> str:
        """Escapa caracteres especiais para SSML"""
        if not text:
            return ""

        # Escapar caracteres XML/SSML
        text = text.replace("&", "&amp;")
        text = text.replace("<", "&lt;")
        text = text.replace(">", "&gt;")
        text = text.replace('"', "&quot;")
        text = text.replace("'", "&apos;")

        return text

    def _extract_language_attributes(self, html_text: str) -> str:
        """
        Extract lang/xml:lang attributes from HTML tags and convert to [[lang:xx]].
        Processes only content tags (p, div, span); ignores structural tags (html, body).

        Exemplo:
            <html lang="pt"><p lang="en">Hello</p></html>
            -> <html lang="pt">[[lang:en]]<p>Hello</p>[[/lang]]</html>
        """
        if not html_text:
            return html_text

        # Structural tags that should be ignored (no [[lang:]] added)
        structural_tags = {
            "html",
            "body",
            "head",
            "article",
            "section",
            "header",
            "footer",
            "main",
            "nav",
        }

        # Process multiple times to capture nested tags
        # Start from the innermost (smallest distance between open and close)
        max_iterations = 10
        for _ in range(max_iterations):
            # Pattern to detect tags with lang attribute
            # Captures: <tag lang="xx" ...> content </tag>
            lang_pattern = re.compile(
                r'<(\w+)\s+([^>]*?)(?:lang|xml:lang)=["\']([a-zA-Z\-]+)["\']([^>]*?)>(.*?)</\1>',
                re.IGNORECASE | re.DOTALL,
            )

            match = lang_pattern.search(html_text)
            if not match:
                break  # No lang tag found

            tag_name = match.group(1).lower()
            attrs_before = match.group(2)
            lang_code = match.group(3)
            attrs_after = match.group(4)
            content = match.group(5)

            # Ignore structural tags to avoid breaking chapters
            if tag_name in structural_tags:
                # Remove only the lang attribute, do not add [[lang:]]
                attrs = (attrs_before + attrs_after).strip()
                if attrs:
                    new_tag = f"<{tag_name} {attrs}>"
                else:
                    new_tag = f"<{tag_name}>"

                replacement = f"{new_tag}{content}</{tag_name}>"
                html_text = html_text[: match.start()] + replacement + html_text[match.end() :]
                continue

            # Remove lang attribute and reconstruct tag without it
            attrs = (attrs_before + attrs_after).strip()
            if attrs:
                new_tag = f"<{tag_name} {attrs}>"
            else:
                new_tag = f"<{tag_name}>"

            # Add language markers around the content
            replacement = f"{new_tag}[[lang:{lang_code}]]{content}[[/lang]]</{tag_name}>"

            # Replace only the first (innermost) occurrence
            html_text = html_text[: match.start()] + replacement + html_text[match.end() :]

        return html_text

    def clean_html_tags(self, text: str) -> str:
        """Remove all HTML tags from text."""
        if not text:
            return text

        # First extract formatting
        text_with_markers = self.extract_formatting(text)

        # Remove remaining HTML tags
        clean_text = re.sub(r"<[^>]+>", "", text_with_markers)

        # Clean up multiple spaces
        clean_text = re.sub(r"\s+", " ", clean_text)

        return clean_text.strip()


__all__ = ["TextFormattingProcessor", "FormattingSegment"]
