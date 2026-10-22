"""Chapter speech for the retained legacy CLI."""

from . import cli_runtime_dependencies as _shared_cli_runtime_dependencies
from .cli_runtime_dependencies import Chapter as Chapter
from .cli_runtime_dependencies import ChapterStructureItem as ChapterStructureItem
from .cli_runtime_dependencies import Dict as Dict
from .cli_runtime_dependencies import EbookReader as EbookReader
from .cli_runtime_dependencies import List as List
from .cli_runtime_dependencies import Optional as Optional
from .cli_runtime_dependencies import argparse as argparse

re = _shared_cli_runtime_dependencies.re

class CLIChapterSpeech:
    def _apply_structure_to_reader(
        self, reader: EbookReader, structure_items: List[ChapterStructureItem]
    ) -> None:
        """Replace reader chapters with structured output for conversion"""

        if not reader.book:
            return

        new_chapters: List[Chapter] = []
        formatter = self._cli_runtime.TextFormattingProcessor()

        for item in structure_items:
            chapter = item.chapter
            formatting_segments = getattr(chapter, "formatting_segments", None)
            if getattr(chapter, "footnotes", None):
                formatting_segments = None

            # Determine text content and ensure headings are spoken
            final_text = item.text_override if item.text_override is not None else chapter.text
            final_text = final_text or ""

            heading_text = self._build_heading_text(item)
            if heading_text:
                normalized_body = final_text.lstrip()
                if not normalized_body.lower().startswith(heading_text.lower()):
                    final_text = f"{heading_text}\n\n{normalized_body}"
                else:
                    final_text = normalized_body
            else:
                final_text = final_text.lstrip()

            # Recompute formatting markers after injecting headings or transforms
            fresh_segments = formatter.parse_formatted_text(final_text)
            formatting_segments = fresh_segments or None

            if self._cli_runtime.PRESERVE_TTS_LAYOUT:
                speech_text = final_text
            else:
                speech_text = formatter.to_audible_text(final_text, formatting_segments)

            # Re-stamp structural speech cues — title announcement
            # ("Capítulo 1...") and "<N> |" / "## N" / bare-number
            # chapter markers — onto speech_text. _apply_text_transforms
            # already did this once on its own copy of speech_text, but
            # this method REBUILDS chapter objects from scratch, so
            # without the second call the brand-new Chapter objects get
            # the cue-less text and the pre-tts cache loses every pause.
            _raw_html_for_cues = getattr(chapter, "raw_html", None)
            _title_for_cues = getattr(chapter, "name", None) or item.display_name
            if _raw_html_for_cues is not None and not isinstance(_raw_html_for_cues, str):
                _raw_html_for_cues = None
            if _title_for_cues is not None and not isinstance(_title_for_cues, str):
                _title_for_cues = None
            speech_text = self._cli_runtime.TextProcessor.apply_structural_speech_cues(
                speech_text,
                raw_html=_raw_html_for_cues,
                chapter_title=_title_for_cues,
            )

            new_chapters.append(
                self._cli_runtime.Chapter(
                    index=item.index,
                    name=item.display_name,
                    source_path=chapter.source_path,
                    text=final_text,
                    level=getattr(chapter, "level", 1),
                    raw_html=getattr(chapter, "raw_html", None),
                    formatting_segments=formatting_segments,
                    footnotes=getattr(chapter, "footnotes", None),
                    speech_text=speech_text,
                )
            )

        reader.book.chapters = new_chapters

    def _build_heading_text(self, item: ChapterStructureItem) -> Optional[str]:
        """Return a clean heading string that should be spoken before the chapter."""

        if not getattr(item, "speak_heading", True):
            return None

        def normalize(value: Optional[str]) -> str:
            return self._cli_runtime.re.sub(r"\s+", " ", value or "").strip()

        main = normalize(item.main_title)
        sub = normalize(item.sub_title)
        parts: List[str] = []

        if sub:
            if main and sub.lower().startswith(main.lower()):
                parts.append(sub)
            else:
                if main:
                    parts.append(main)
                parts.append(sub)
        elif main:
            parts.append(main)
        else:
            fallback = normalize(item.display_name)
            if fallback:
                parts.append(fallback)

        heading = "\n".join(parts).strip()
        return heading or None

    @staticmethod
    def _remove_inline_footnotes(text: str, *, namespace) -> str:
        if not text:
            return ""
        pattern = namespace.re.compile(
            r"\s*nota de rodapé\s+\d+:[^\n]*?fim da nota de rodapé\s+\d+\s*",
            namespace.re.IGNORECASE,
        )
        cleaned = pattern.sub(" ", text)
        return namespace.re.sub(r"\s+", " ", cleaned).strip()

    @staticmethod
    def _strip_book_title_prefix(text: str, book_title: Optional[str], *, namespace) -> str:
        if not text:
            return ""
        if not book_title:
            return text.lstrip()

        title = str(book_title).strip()
        if not title:
            return text.lstrip()

        cleaned = text.lstrip()
        suffix_chars = " \t\r\n,.:;-–—“”\"'"
        title_folded = title.casefold()
        while cleaned[: len(title)].casefold() == title_folded:
            cleaned = cleaned[len(title) :].lstrip(suffix_chars)

        def normalise(value: str) -> str:
            value = value or ""
            value = namespace.unicodedata.normalize("NFKD", value).casefold()
            return "".join(ch for ch in value if ch.isalnum())

        title_norm = normalise(title)
        lines = cleaned.splitlines()
        while lines and title_norm and normalise(lines[0]) == title_norm:
            lines.pop(0)
        cleaned = "\n".join(lines).lstrip()
        return cleaned

    def _prepare_chapter_text(
        self, raw_text: str, *, display_name: str, book_title: Optional[str]
    ) -> str:
        """Normalise chapter text to ensure parity between cache and audio."""
        text = raw_text or ""
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        text = self._strip_book_title_prefix(text, book_title)
        text = self._deduplicate_heading(text, display_name)
        lines = [line.strip() for line in text.split("\n")]

        display_parts = [part.strip() for part in display_name.split(" - ") if part.strip()]
        ignored_candidates = [display_name] + display_parts[:-1]
        ignored_norms = {self._normalize_lookup(part) for part in ignored_candidates if part}
        if book_title:
            ignored_norms.add(self._normalize_lookup(book_title))

        # Remove redundant consecutive headings and empty lines
        cleaned_lines: list[str] = []
        for line in lines:
            if not line:
                if cleaned_lines and cleaned_lines[-1] != "":
                    cleaned_lines.append("")
                continue

            normalised_line = self._normalize_lookup(line)
            if normalised_line in ignored_norms:
                continue

            if cleaned_lines:
                last = cleaned_lines[-1]
                # Only deduplicate short heading-like lines (≤8 words).
                # Long body sentences may naturally contain the same words as a
                # preceding heading (e.g. "Quarto de Eddie" followed by
                # "...subiram para o quarto de Eddie.") — do not drop the heading.
                _MAX_HEADING_WORDS = 8
                line_is_heading = len(line.split()) <= _MAX_HEADING_WORDS
                last_is_heading = len(last.split()) <= _MAX_HEADING_WORDS
                if last_is_heading and line_is_heading and self._heading_contains(line, last):
                    cleaned_lines[-1] = line
                    continue
                if last_is_heading and line_is_heading and self._heading_contains(last, line):
                    # Skip current line if previous already more descriptive
                    continue

            cleaned_lines.append(line)

        while cleaned_lines and not cleaned_lines[0]:
            cleaned_lines.pop(0)
        while cleaned_lines and not cleaned_lines[-1]:
            cleaned_lines.pop()

        if cleaned_lines and cleaned_lines[-1].lower() in {"notas", "nota"}:
            cleaned_lines.pop()

        text = "\n".join(cleaned_lines)
        text = self._cli_runtime.re.sub(r"\n{3,}", "\n\n", text)
        text = self._cli_runtime.re.sub(r"[\t ]+\n", "\n", text)
        text = self._cli_runtime.re.sub(r"\n[\t ]+", "\n", text)
        text = self._cli_runtime.re.sub(r"\)\s+\.", ").", text)
        text = self._cli_runtime.re.sub(r"\s+\)", ")", text)
        return text.strip()

    @staticmethod
    def _text_signature(text: str) -> str:
        if not text:
            return ""
        import re

        return re.sub(r"\s+", " ", text).strip().lower()

    def _footnote_phrases(self, language: Optional[str]) -> Dict[str, str]:
        lang = (language or "").split("-", 1)[0].lower()
        if lang != "en" and lang != "pt":
            lang = "pt"
        if lang == "en":
            return {
                "prefix": "\n",
                "template": "footnote {number}: {text}",
                "suffix_text": " end of footnote",
                "closing": "",
                "chapter_end_template": "footnote {number}: {snippet} - {text} end of footnote",
            }

        return {
            "prefix": "\n",
            "template": "nota de rodapé {number}: {text}",
            "suffix_text": " fim da nota de rodapé",
            "closing": "",
            "chapter_end_template": "nota de rodapé {number}: {snippet} - {text} fim da nota de rodapé",
        }

    @staticmethod
    def _deduplicate_heading(text: str, display_name: str, *, namespace) -> str:
        if not text:
            return text

        lines = text.splitlines()
        if not lines:
            return text

        def normalise(value: str) -> str:
            value = value or ""
            value = namespace.unicodedata.normalize("NFKD", value).casefold()
            return "".join(ch for ch in value if ch.isalnum())

        display_norm = normalise(display_name)

        for idx, line in enumerate(lines):
            stripped = line.strip()
            if not stripped:
                continue
            if display_norm and normalise(stripped) == display_norm:
                lines.pop(idx)
            break

        cleaned: list[str] = []
        previous_norm = None
        for line in lines:
            stripped = line.strip()
            if not stripped:
                cleaned.append(line)
                previous_norm = None
                continue
            current_norm = normalise(stripped)
            if previous_norm and current_norm == previous_norm:
                continue
            cleaned.append(line)
            previous_norm = current_norm

        return "\n".join(cleaned).strip()

    @staticmethod
    def _resolve_footnote_mode(args: argparse.Namespace) -> str:
        if getattr(args, "no_footnote", False):
            return "skip"
        if getattr(args, "footnote_chapter_end", False):
            return "chapter_end"
        return "inline"
