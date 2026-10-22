"""Validate saved text payloads against original chapter content."""

from __future__ import annotations

import re
from typing import List

from ._output_file_helpers import sample_edges as _sample_edges_helper
from .ebook_reader import Chapter
from .text_integrity_validator import TextIntegrityValidator


class OutputTextIntegrity:
    @staticmethod
    def _speech_text(chapter: Chapter) -> str:
        text = getattr(chapter, "speech_text", None)
        if text is None:
            text = chapter.text or ""
        return text

    @staticmethod
    def _spot_check_text_against_epub(epub_text: str, payload: str) -> bool:
        """Lightweight spot-check: ensure key snippets from EPUB exist in the TTS payload."""
        if not epub_text or not payload:
            return False

        def normalize(val: str) -> str:
            val = re.sub(r"\s+", " ", val or "")
            return val.strip().lower()

        epub_norm = normalize(epub_text)
        payload_norm = normalize(payload)
        if not epub_norm or not payload_norm:
            return False

        # Take first snippet and a middle snippet to detect truncation/duplication.
        first_snippet = epub_norm[:200]
        mid_start = max(len(epub_norm) // 2 - 100, 0)
        mid_snippet = epub_norm[mid_start : mid_start + 200]

        first_ok = first_snippet in payload_norm
        mid_ok = mid_snippet in payload_norm
        return first_ok and mid_ok

    @staticmethod
    def _sample_edges(text: str, size: int = 180) -> tuple[str, str]:
        return _sample_edges_helper(text, size)

    @staticmethod
    def _strip_formatting_cues(text: str) -> str:
        """Remove audible formatting cue phrases from text."""
        if not text:
            return ""
        try:
            from .text_formatting import TextFormattingProcessor

            phrases: set[str] = set()
            for locale_map in TextFormattingProcessor.CUE_LABELS.values():
                for start, end in locale_map.values():
                    phrases.add(start)
                    phrases.add(end)
            phrases.update(TextFormattingProcessor.FOOTNOTE_END_PHRASES)
        except Exception:
            return text

        cleaned = text
        for phrase in sorted(phrases, key=len, reverse=True):
            cleaned = re.sub(re.escape(phrase), "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        return cleaned

    def _validate_text_after_save(
        self,
        chapter: Chapter,
        chapter_label: str,
        parsed_text: str,
        pre_tts_text: str,
        *,
        validator: "TextIntegrityValidator",
        strict: bool,
    ) -> bool:
        """Validate parsed/pre-tts text against EPUB content."""
        issues: List[str] = []
        epub_text = chapter.text or ""
        parsed_norm = validator.normalize_text(parsed_text)
        epub_norm = validator.normalize_text(epub_text)

        if not parsed_norm:
            issues.append("chapter text is empty or not extracted from EPUB")
        if epub_norm:
            diff = len(epub_norm) - len(parsed_norm)
            allowed_diff = max(50, int(len(epub_norm) * 0.05))
            if abs(diff) > allowed_diff:
                issues.append(f"text divergente do EPUB ({diff:+d} chars)")
            start, end = self._sample_edges(epub_norm)
            if start and start not in parsed_norm:
                issues.append("text parsed sem start do EPUB")
            if end and end not in parsed_norm:
                issues.append("text parsed sem final do EPUB")

        if parsed_norm:
            text_hash = validator.calculate_text_hash(parsed_norm)
            if text_hash in self._text_validation_hashes:
                other = self._text_validation_hashes[text_hash]
                # Only flag as duplicate if it's a different chapter
                # (validation may be called multiple times for same chapter during retries)
                if other != chapter_label:
                    issues.append(f"Duplicate content (same as chapter {other})")
            else:
                # Use full chapter label instead of just integer index to avoid false positives
                # for subchapters (4.1, 4.2, etc.) which all have the same integer part
                self._text_validation_hashes[text_hash] = chapter_label

            snippet = parsed_norm[:200]
            if snippet and parsed_norm.count(snippet) > 1:
                issues.append("Possible internal duplication (repeated snippet)")
            if len(parsed_norm) > 400 and parsed_norm[:200] == parsed_norm[-200:]:
                issues.append("Possible internal duplication (start = end)")

        if pre_tts_text and parsed_norm:
            pretts_norm = validator.normalize_text(self._strip_formatting_cues(pre_tts_text))
            # Pre-TTS text may have chapter announcements and formatting cues prepended/appended
            # So we check if substantial portions of the parsed text appear anywhere in pre-TTS
            # rather than checking exact beginning/end positions
            if len(parsed_norm) > 300:
                # Sample from middle sections to avoid chapter announcement additions
                mid_start = len(parsed_norm) // 4
                mid_sample_size = min(200, len(parsed_norm) // 2)
                mid_sample = parsed_norm[mid_start : mid_start + mid_sample_size]

                # Check if middle portion exists in pre-TTS (more reliable than start/end)
                if mid_sample and mid_sample not in pretts_norm:
                    # Length check: pre-TTS should be similar length to parsed (within 20%)
                    len_ratio = len(pretts_norm) / len(parsed_norm) if len(parsed_norm) > 0 else 0
                    if len_ratio < 0.8 or len_ratio > 1.5:
                        issues.append(
                            f"Pre-TTS tem tamanho muito diferente do parsed ({len_ratio:.1%})"
                        )

        if issues:
            message = f"Post-parsing validation failed ({chapter_label}): {', '.join(issues)}"
            self._text_validation_errors.append(message)
            if self.verbose:
                print(f"❌ {message}")
            if strict:
                raise RuntimeError(message)
            return False

        return True
