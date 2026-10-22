# -*- coding: utf-8 -*-
"""EPUB chapter deduplication and content fidelity checks."""

from __future__ import annotations

from typing import List

from .ebook_models import Chapter


class EpubContentIntegrity:
    """EPUB chapter deduplication and content fidelity checks."""

    def _remove_duplicate_chapters(self, chapters: List[Chapter]) -> List[Chapter]:
        """Remove chapters that have duplicate/overlapping content.

        This avoids creating separate entries for subchapters that repeat
        content already present in other chapters.
        """
        if not chapters:
            return chapters

        # Strategy: keep only chapters with unique content
        # For each chapter, extract "unique core" (content that doesn't appear in others)
        # Remove chapters whose content is 90%+ contained in other chapters

        # Step 1: normalize all texts
        normalized_texts = []
        for chapter in chapters:
            normalized_texts.append(self._normalize_for_comparison(chapter.text.strip()))

        # Step 2: identify chapters to remove
        chapters_to_keep = []
        removed_chapters = []

        for i, chapter in enumerate(chapters):
            current_norm = normalized_texts[i]

            # Empty or very short chapters: check if they're just dividers
            if len(current_norm) < 50:
                # Very short chapter, probably just a title
                removed_chapters.append(chapter)
                continue

            # Check if this chapter has unique significant content
            has_unique_content = True

            # Extract chapter "core" (first 500 chars after cleaning)
            core_content = current_norm[:500] if len(current_norm) > 500 else current_norm

            # Extract multiple text "windows" for comparison
            # Detects repeated content even with different prefixes
            windows = []
            window_size = 300
            step = 150  # Janelas sobrepostas
            for start in range(0, len(current_norm) - window_size, step):
                windows.append(current_norm[start : start + window_size])

            # Check if the core appears in other chapters (before or after)
            for j, other_chapter in enumerate(chapters):
                if i == j:
                    continue

                other_norm = normalized_texts[j]

                # If another chapter is larger and contains our core
                if len(other_norm) > len(current_norm) and core_content in other_norm:
                    # This chapter is a subset of a larger one
                    has_unique_content = False
                    break

                # Check if ANY significant text window appears in another chapter
                if len(other_norm) > len(current_norm):
                    for window in windows:
                        if len(window) >= 200 and window in other_norm:
                            # A significant portion of the text is repeated
                            has_unique_content = False
                            break
                    if not has_unique_content:
                        break

                # If another chapter is similar in size (±30%) and has high overlap
                if abs(len(other_norm) - len(current_norm)) < len(current_norm) * 0.3:
                    overlap = self._calculate_text_overlap(current_norm, other_norm)
                    if overlap > 0.6:  # 60% overlap
                        # Manter o que veio primeiro (ou o maior)
                        if j < i or len(other_norm) > len(current_norm):
                            has_unique_content = False
                            break

            if has_unique_content:
                chapters_to_keep.append(chapter)
            else:
                removed_chapters.append(chapter)

        # Integrity check: ensure no content was lost
        self._verify_content_integrity(chapters, chapters_to_keep, removed_chapters)

        return chapters_to_keep

    def _calculate_text_overlap(self, text1: str, text2: str) -> float:
        """Calculate overlap percentage between two texts using n-grams."""
        if not text1 or not text2:
            return 0.0

        # Use 3-grams (sequences of 3 words)
        words1 = text1.split()
        words2 = text2.split()

        if len(words1) < 3 or len(words2) < 3:
            # Textos muito curtos, comparar diretamente
            return 1.0 if text1 == text2 else 0.0

        # Criar conjuntos de 3-gramas
        ngrams1 = set()
        for i in range(len(words1) - 2):
            ngrams1.add(" ".join(words1[i : i + 3]))

        ngrams2 = set()
        for i in range(len(words2) - 2):
            ngrams2.add(" ".join(words2[i : i + 3]))

        if not ngrams1 or not ngrams2:
            return 0.0

        # Compute overlap (Jaccard similarity)
        intersection = ngrams1 & ngrams2
        union = ngrams1 | ngrams2

        return len(intersection) / len(union) if union else 0.0

    def _normalize_for_comparison(self, text: str) -> str:
        """Normalise text for comparison by removing markup and formatting."""
        from . import ebook_reader as _runtime
        if not text:
            return ""

        # Remove Markdown markup
        cleaned = _runtime.re.sub(r"\*+", "", text)  # Remove asteriscos
        cleaned = _runtime.re.sub(r"_+", "", cleaned)  # Remove underscores
        cleaned = _runtime.re.sub(r"\[\[.*?\]\]", "", cleaned)  # Remove marcadores [[...]]
        cleaned = _runtime.re.sub(r"§\s*\d+", "", cleaned)  # Remove sections §1, §2, etc.

        # Normalize whitespace
        cleaned = " ".join(cleaned.split())

        # Remove common leading punctuation
        cleaned = cleaned.lstrip(" .-:")

        return cleaned.lower()

    def _verify_content_integrity(
        self,
        original_chapters: List[Chapter],
        filtered_chapters: List[Chapter],
        removed_chapters: List[Chapter],
    ) -> None:
        """Verify that all original content is present after filtering.

        Compares total content to ensure no text was lost.
        """
        # Extract all unique words from the original (normalized to ignore formatting)
        original_words = set()
        for chapter in original_chapters:
            normalized = self._normalize_for_comparison(chapter.text.strip())
            words = normalized.split()
            # Filter out very short words (likely markup)
            words = [w for w in words if len(w) > 2]
            original_words.update(words)

        # Extract all unique words from filtered chapters
        filtered_words = set()
        for chapter in filtered_chapters:
            normalized = self._normalize_for_comparison(chapter.text.strip())
            words = normalized.split()
            words = [w for w in words if len(w) > 2]
            filtered_words.update(words)

        # Check for missing words
        missing_words = original_words - filtered_words

        # Filter out words that are only markup or isolated numbers
        significant_missing = set()
        for word in missing_words:
            # Ignore pure numbers, very short words, or markup
            if word.isdigit() or len(word) <= 3:
                continue
            # Ignorar palavras com muitos caracteres especiais
            alpha_ratio = sum(1 for c in word if c.isalpha()) / len(word) if word else 0
            if alpha_ratio < 0.5:
                continue
            significant_missing.add(word)

        if significant_missing:
            # Significant content is missing — this is a problem.
            missing_sample = list(significant_missing)[:20]
            print("⚠️ WARNING: Possibly lost content detected during duplicate filtering!")
            print(f"   Palavras faltando (amostra): {' '.join(missing_sample)}")
            print(f"   Total unique words missing: {len(significant_missing)}")

            # Identify which removed chapters had unique content
            for removed in removed_chapters:
                removed_normalized = self._normalize_for_comparison(removed.text.strip())
                removed_words = set(w for w in removed_normalized.split() if len(w) > 3)
                removed_unique = removed_words - filtered_words
                # Filter out markup
                removed_unique = set(
                    w
                    for w in removed_unique
                    if w and len(w) > 0 and sum(1 for c in w if c.isalpha()) / len(w) >= 0.5
                )
                if removed_unique:
                    print(
                        f"   ❌ Capítulo '{removed.name}' tinha {len(removed_unique)} palavras únicas perdidas"
                    )

            # Restore removed chapters that had unique content
            # Do NOT do this automatically — only warn
            raise ValueError(
                f"Integrity check failed: {len(significant_missing)} unique words lost. "
                "The duplicate removal algorithm needs adjustment."
            )
