"""Division titles for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    re as re,
)

class CLIDivisionTitles:
    PREVIEW_WORD_LIMIT = 30
    FOOTNOTE_CONTEXT_WORDS = 8

    def _is_main_division(self, name: str) -> bool:
        """Check if this is a main division (like Livro primeiro, Capítulo X)"""
        if not name:
            return False

        import re

        name_lower = name.lower()

        # Look for book divisions
        division_patterns = [
            r"livro\s+(primeiro|segundo|terceiro|quarto|quinto)",
            r"livro\s+[ivx]+",
            r"book\s+(first|second|third|fourth|fifth)",
            r"book\s+[ivx]+",
            r"parte\s+[ivx\d]+",
            r"seção\s+[ivx\d]+",
            r"capítulo\s+\d+",  # Matches "Capítulo 1", "Capítulo 2", etc.
            r"chapter\s+\d+",  # Chapter 1, 2, etc.
        ]

        for pattern in division_patterns:
            if re.search(pattern, name_lower):
                return True

        return False

    def _clean_main_division_name(self, name: str) -> str:
        """Clean up main division name to remove redundancy"""
        if not name:
            return name

        import re

        # For "Livro primeiro - livro primeiro DUNA", keep just "Livro primeiro"
        parts = [part.strip() for part in name.split(" - ") if part.strip()]

        # Find the best representative part
        best_part = ""
        for part in parts:
            part_lower = part.lower()
            if re.search(r"livro\s+(primeiro|segundo|terceiro)", part_lower) or re.search(
                r"capítulo\s+\d+", part_lower
            ):
                # Prefer the capitalized version
                if part[0].isupper():
                    best_part = part
                elif not best_part:
                    best_part = part

        return best_part if best_part else parts[0] if parts else name

    def _remove_redundant_main_name(self, chapter_name: str, main_name: str) -> str:
        """Remove redundant main name from chapter name"""
        if not chapter_name or not main_name:
            return chapter_name

        # Remove main name parts from chapter name
        main_lower = main_name.lower()
        parts = [part.strip() for part in chapter_name.split(" - ") if part.strip()]

        # Filter out parts that are redundant with main name
        filtered_parts = []
        for part in parts:
            part_lower = part.lower()
            if part_lower != main_lower and main_lower not in part_lower:
                filtered_parts.append(part)

        return " - ".join(filtered_parts) if filtered_parts else chapter_name

    def _is_division_candidate(self, chapter, chapters, index) -> bool:
        text = str(getattr(chapter, "text", "")).strip()
        if index < 3:
            return False
        if len(text) > 400:
            return False
        if index + 1 >= len(chapters):
            return False
        next_text = str(getattr(chapters[index + 1], "text", "")).strip()
        return len(next_text) > 1500

    def _is_substantial_chapter(self, text: str) -> bool:
        """Check if chapter has substantial content"""
        return len(text.strip()) > 5000  # At least 5000 characters

    def _find_main_chapter_for(self, chapters, current_index):
        """Find the main chapter number this subchapter belongs to"""
        # Look backwards for the last main division
        main_counter = 0
        for i in range(current_index):
            chapter = chapters[i]
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1

        return main_counter if main_counter > 0 else 1

    def _count_subchapters_before(self, chapters, current_index, main_chapter_num):
        """Count how many subchapters exist before this one for the same main chapter"""
        # Find the start index of this main chapter
        main_counter = 0
        main_start_index = 0

        for i in range(current_index):
            chapter = chapters[i]
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1
                if main_counter == main_chapter_num:
                    main_start_index = i
                    break

        # Count substantial subchapters between main chapter and current
        subchapter_count = 1
        for i in range(main_start_index + 1, current_index):
            chapter = chapters[i]
            if self._is_substantial_chapter(chapter.text):
                subchapter_count += 1

        return subchapter_count

    def _get_main_chapter_name(self, chapters, main_chapter_num):
        """Get the name of the main chapter by number"""
        main_counter = 0
        for chapter in chapters:
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1
                if main_counter == main_chapter_num:
                    return clean_name
        return None

    def _extract_first_words(self, text: str, max_words: int = PREVIEW_WORD_LIMIT) -> str:
        """Extract first words from text content"""
        if not text or not text.strip():
            return ""

        import re

        # Remove language tags [[lang:xx]] and [[/lang]] before extracting words
        clean_text = re.sub(r"\[\[lang:[a-zA-Z\-]+\]\]", "", text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\[\[/lang\]\]", "", clean_text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\s+", " ", clean_text.strip())
        words = clean_text.split()[:max_words]
        return " ".join(words)

    def _extract_smart_first_words(
        self, text: str, clean_name: str, main_div_name: str, max_words: int = 15
    ) -> str:
        """Extract first words avoiding repetition of chapter/section titles"""
        if not text or not text.strip():
            return ""

        import re

        # Remove language tags [[lang:xx]] and [[/lang]] before extracting words
        clean_text = re.sub(r"\[\[lang:[a-zA-Z\-]+\]\]", "", text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\[\[/lang\]\]", "", clean_text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\s+", " ", clean_text.strip())

        # Remove common patterns that repeat the title information
        patterns_to_remove = []

        # Add patterns based on clean_name
        if clean_name:
            # Remove exact matches
            patterns_to_remove.append(re.escape(clean_name.lower()))

            # Extract key parts of the clean name for removal
            if "§" in clean_name:
                # For sections like "§1 Introduction", remove both the heading and section references
                section_parts = clean_name.split(" ")
                for part in section_parts:
                    if len(part) > 3 and part not in ["§1", "§2", "§3", "§4", "§5"]:
                        patterns_to_remove.append(re.escape(part.lower()))

            if "Capítulo" in clean_name:
                # Remove "capítulo X" (chapter heading) references
                patterns_to_remove.append(r"capítulo\s+\d+")

        # Always strip generic "capitulo X" patterns from previews
        patterns_to_remove.append(r"cap[íi]tulo\s+\d+")

        # Add patterns based on main_div_name
        if main_div_name:
            patterns_to_remove.append(re.escape(main_div_name.lower()))

        # Clean the text by removing these patterns
        text_lower = clean_text.lower()
        for pattern in patterns_to_remove:
            if pattern:
                text_lower = re.sub(pattern, "", text_lower, flags=re.IGNORECASE)

        # Clean up extra spaces and get the result
        text_lower = re.sub(r"\s+", " ", text_lower.strip())

        # If we removed too much, fall back to original approach
        if len(text_lower.strip()) < 10:
            return self._extract_first_words(clean_text, max_words)

        # Extract words from cleaned text
        words = text_lower.split()[:max_words]
        result = " ".join(words)

        # Capitalize first letter
        if result:
            result = result[0].upper() + result[1:] if len(result) > 1 else result.upper()

        return result if result else self._extract_first_words(clean_text, max_words)
