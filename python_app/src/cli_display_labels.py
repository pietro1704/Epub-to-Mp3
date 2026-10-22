"""Display labels for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    Optional as Optional,
    re as re,
)

class CLIDisplayLabels:
    def _sanitize_first_words(self, first_words: str, *phrases: str) -> str:
        """Remove redundant leading phrases from extracted first words"""
        if not first_words:
            return ""

        cleaned = first_words.strip()
        if not cleaned:
            return ""

        import re

        for phrase in phrases:
            if not phrase:
                continue
            phrase_clean = phrase.strip()
            if not phrase_clean:
                continue

            pattern = rf"^{re.escape(phrase_clean)}[\s\-–—,:;]*"
            cleaned = re.sub(pattern, "", cleaned, flags=re.IGNORECASE)

        return cleaned.strip(" -—–,:;!?\"'()[]{}")

    def _sanitize_display_values(
        self, main_name, sub_name, first_words, book_title, book_author=None
    ):
        """Clean display values to avoid repeating the book title or duplicates"""

        book_title_clean = (book_title or "").strip()
        book_author_clean = (book_author or "").strip()

        def cleanse(value: Optional[str]) -> str:
            if not value:
                return ""
            cleaned = str(value).strip()
            if not cleaned:
                return ""
            if book_title_clean and cleaned.lower() == book_title_clean.lower():
                return ""
            if book_author_clean and cleaned.lower() == book_author_clean.lower():
                return ""
            if book_title_clean:
                title_pattern = self._cli_runtime.re.escape(book_title_clean)
                # Remove parenthetical fragments that still reference the book title
                cleaned = self._cli_runtime.re.sub(
                    rf"\(\s*[^)]*{title_pattern}[^)]*\)",
                    "",
                    cleaned,
                    flags=self._cli_runtime.re.IGNORECASE,
                )
                pattern = self._cli_runtime.re.compile(title_pattern, self._cli_runtime.re.IGNORECASE)
                cleaned = pattern.sub("", cleaned)
                cleaned = self._cli_runtime.re.sub(r"\s+", " ", cleaned)
                cleaned = cleaned.strip()
                cleaned = self._cli_runtime.re.sub(r"\s+([)\]}])", r"\1", cleaned)
                cleaned = self._cli_runtime.re.sub(r"([\(\[\{])\s+", r"\1", cleaned)
                cleaned = self._cli_runtime.re.sub(r"\(\s*\)", "", cleaned)
                cleaned = self._cli_runtime.re.sub(r"\[\s*\]", "", cleaned)
                cleaned = self._cli_runtime.re.sub(r"\{\s*\}", "", cleaned)
            if book_author_clean:
                author_pattern = self._cli_runtime.re.escape(book_author_clean)
                cleaned = self._cli_runtime.re.sub(author_pattern, "", cleaned, flags=self._cli_runtime.re.IGNORECASE)
                cleaned = self._cli_runtime.re.sub(r"\s+", " ", cleaned)
                cleaned = cleaned.strip()
            cleaned = cleaned.strip(" -–—,:;")
            return cleaned

        main = cleanse(main_name)
        sub = cleanse(sub_name)
        first = cleanse(first_words)

        seen = set()

        def unique(value: str) -> str:
            if not value:
                return ""
            lowered = value.lower()
            if lowered in seen:
                return ""
            seen.add(lowered)
            return value

        main = unique(main)
        sub = unique(sub)
        first = unique(first)

        def normalise_case(value: Optional[str]) -> Optional[str]:
            if not value:
                return value
            stripped = value.strip()
            if not stripped:
                return None
            if stripped.lower() == stripped:
                return stripped[:1].upper() + stripped[1:]
            return stripped

        main = normalise_case(main)
        sub = normalise_case(sub)
        first = normalise_case(first)

        return (main or None, sub or None, first or None)

    def _remove_duplicate_prefix(self, preview: Optional[str], *references: Optional[str]):
        if not preview:
            return None

        import re

        cleaned = preview.strip()
        for ref in references:
            if not ref:
                continue
            ref_clean = str(ref).strip()
            if not ref_clean:
                continue

            # Remove exact matches at start
            if cleaned.lower().startswith(ref_clean.lower()):
                cleaned = cleaned[len(ref_clean) :].strip(" -–—,:;")

            # Remove partial word matches too
            ref_words = ref_clean.lower().split()
            for word in ref_words:
                if len(word) > 3:  # Only for significant words
                    pattern = r"\b" + re.escape(word) + r"\b"
                    cleaned = re.sub(pattern, "", cleaned, flags=re.IGNORECASE).strip()

        # Clean up multiple spaces and separators
        cleaned = re.sub(r"[-–—,:;\s]+", " ", cleaned).strip()

        cleaned = re.sub(r"^(?:\d+\s+){1,3}", "", cleaned).strip()

        return cleaned or None

    def _parse_leading_number(self, raw_index: str) -> Optional[int]:
        try:
            return int(raw_index.split()[0])
        except (ValueError, IndexError):
            return None

    def _format_chapter_display(
        self, chapter, chapters, current_index, book_title, book_author=None
    ):
        """Format chapter display generically without book-specific rules"""

        text = str(getattr(chapter, "text", ""))
        name = str(getattr(chapter, "name", "")).strip()

        if len(text.strip()) < 5 and not name:
            return None

        index = self._format_index_value(chapter, current_index)
        clean_name = self._clean_chapter_name(name)
        preview = self._extract_first_words(text, self.PREVIEW_WORD_LIMIT)

        main_name, sub_name, preview = self._sanitize_display_values(
            clean_name, None, preview, book_title, book_author
        )

        label = self._detect_section_label(clean_name, text, current_index)
        if label:
            main_name = label

        if not any((main_name, sub_name, preview)):
            fallback_preview = self._extract_first_words(text, min(self.PREVIEW_WORD_LIMIT, 20))
            main_name = clean_name or fallback_preview or f"Chapter {current_index + 1}"
            sub_name = None
            preview = None

        preview = self._remove_duplicate_prefix(preview, main_name, sub_name)

        return (index, main_name, sub_name, preview)

    def _detect_section_label(self, clean_name: str, text: str, position: int) -> Optional[str]:
        lower_name = (clean_name or "").lower()
        lower_text = (text or "").lower()

        if position <= 5:
            if any(
                keyword in lower_name or keyword in lower_text for keyword in ("sumário", "sumario")
            ):
                labels = []
                if (
                    "sumário" in lower_name
                    or "sumario" in lower_name
                    or "sumário" in lower_text
                    or "sumario" in lower_text
                ):
                    labels.append("Sumário")
                if "capa" in lower_name or "capa" in lower_text:
                    labels.append("Capa")
                if "folha de rosto" in lower_name or "folha de rosto" in lower_text:
                    labels.append("Folha de rosto")
                return "/".join(labels) if labels else "Sumário"
            if (
                any(keyword in lower_name for keyword in ("introdu", "prefácio"))
                or any(keyword in lower_text for keyword in ("introdu", "prefácio"))
                or (
                    len(lower_text) > 800
                    and "capítulo" not in lower_text
                    and "dedic" not in lower_text
                )
            ):
                return "Introdução"
            if "dedic" in lower_name or "dedic" in lower_text:
                return "Dedicatória"

        return None

    def _format_index_value(self, chapter, position):
        raw_index = getattr(chapter, "index", None)
        if isinstance(raw_index, str) and raw_index.strip():
            return raw_index.strip()
        if isinstance(raw_index, (int, float)):
            return str(raw_index)
        return str(position + 1)
