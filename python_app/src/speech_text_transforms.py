"""Stateless speech text transforms that preserve layout and subclass policy hooks."""

import re


class SpeechTextTransforms:
    """Lexical cleanup and inline emphasis shared by formatting renderers."""

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
