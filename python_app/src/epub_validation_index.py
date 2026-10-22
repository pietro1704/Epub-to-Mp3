"""Build and query content-based EPUB chapter identity for deep validation."""

from typing import Optional


class EpubValidationIndex:
    @staticmethod
    def _content_fingerprint(text: str, word_count: int = 40) -> str:
        """Return a fingerprint from the *last* ``word_count`` words of *text*.

        We use the end of the text because the converter may prepend
        section / part headers (e.g. "Parte 1 – A sombra antes") that
        don't exist in the raw EbookReader chapter text, but the ending
        is always identical.
        """
        words = text.split()
        if len(words) <= word_count:
            return " ".join(w.lower() for w in words)
        segment = words[-word_count:]
        return " ".join(w.lower() for w in segment)

    def _find_epub_match(self, parsed_clean: str) -> Optional[str]:
        """Find matching EPUB chapter text for a parsed file's content.

        Strategy (in order):
        1. Fingerprint lookup on last-N-words (O(1), handles most chapters).
        2. Full containment check — does the EbookReader text appear
           verbatim inside the parsed text?  Handles short chapters
           where headers dominate.
        3. Partial-tail check — do the last 20 words of the EbookReader
           chapter appear in the parsed text?  Handles cases where the
           converter slightly trims or extends the text.
        """
        # 1. Fingerprint
        fp = self._content_fingerprint(parsed_clean)
        epub_text = self.epub_chapters.get(fp)
        if epub_text is not None:
            return epub_text

        parsed_lower = parsed_clean.lower()

        best_candidate = None
        best_overlap = 0.0

        parsed_words = set(parsed_lower.split())

        for _fp, candidate in self.epub_chapters.items():
            cand_lower = candidate.lower()

            # 2. Full containment
            if cand_lower in parsed_lower:
                return candidate

            # 3. Partial-tail: last 20 words of epub in parsed
            cand_words_list = cand_lower.split()
            if len(cand_words_list) > 20:
                tail = " ".join(cand_words_list[-20:])
                if tail in parsed_lower:
                    return candidate

            # 4. Track best fuzzy match by word overlap
            cand_words = set(cand_words_list)
            if cand_words and parsed_words:
                overlap = len(cand_words & parsed_words) / max(len(cand_words), len(parsed_words))
                if overlap > best_overlap:
                    best_overlap = overlap
                    best_candidate = candidate

        # Accept the best fuzzy match if word overlap >= 80%
        if best_candidate is not None and best_overlap >= 0.8:
            return best_candidate

        return None

    def load_epub_chapters(self) -> bool:
        """Load and parse all chapters from the original EPUB using EbookReader.

        Uses the same parsing pipeline as the converter (footnotes, formatting,
        pauses) so that validation compares identical text representations.

        Chapters are indexed by a content fingerprint (first N words) because
        the converter may relabel chapter indices via TOC structure (e.g.
        ``1`` → ``"4.1"``), making raw index matching unreliable.
        """
        try:
            from .ebook_reader import EbookReader

            reader = EbookReader(self.epub_path)
            chapters = reader.get_chapters()
            self._chapter_list = chapters

            for ch in chapters:
                text = ch.text or ""
                text_clean = " ".join(text.split())
                if len(text_clean) > 50:  # Skip very small chapters
                    fp = self._content_fingerprint(text_clean)
                    self.epub_chapters[fp] = text_clean

            return len(self.epub_chapters) > 0
        except Exception as e:
            print(f"❌ Error loading EPUB: {e}")
            return False
