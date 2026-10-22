# -*- coding: utf-8 -*-
"""
Text formatting detection and markup system for audio differentiation
"""

import os
import re
from dataclasses import dataclass
from typing import List, Optional, Sequence

from .formatting_language_markup import extract_language_attributes
from .speech_text_transforms import SpeechTextTransforms


@dataclass
class FormattingSegment:
    """Text segment with specific formatting"""

    text: str
    formatting: str  # 'normal', 'italic', 'bold', 'emphasis', 'strong', etc.
    language: Optional[str] = None


PRESERVE_TTS_LAYOUT = os.getenv("PRESERVE_TTS_LAYOUT", "1").lower() in ("1", "true", "yes")


class TextFormattingProcessor(SpeechTextTransforms):
    """Text formatting processor for audio differentiation"""

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
            # NOTE: <small> is intentionally excluded here.
            # In EPUBs it is almost always used for typographic small-caps
            # (e.g. `B<small>RUNO</small>` → "BRUNO"), not semantic "smaller
            # text".  Extracting it as a formatting segment splits words across
            # segment boundaries and loses line-structure.  The standard HTML
            # stripper handles it correctly when left as plain markup.
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

            if segment.formatting in {"italic", "bold", "emphasis", "code", "quote"}:
                start, end = self._get_cue_phrases(segment.formatting)
                formatted = self._render_with_cues(start, text, end)
                parts.append(formatted)
            else:
                # "small" (<small>, <sub>, <sup>) is used for typography/small-caps in EPUBs
                # and should be read as normal text without verbal cues.
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
        return extract_language_attributes(html_text)

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
