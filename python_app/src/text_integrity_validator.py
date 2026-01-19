# -*- coding: utf-8 -*-
"""
Text Integrity Validator - Validates EPUB text before and during audio conversion

This module ensures no text is lost, duplicated, or corrupted during the conversion process.
"""

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

from .ebook_reader import Chapter


@dataclass
class ChapterTextValidation:
    """Validation result for a single chapter's text"""

    chapter_index: int
    chapter_title: str
    epub_char_count: int
    cached_char_count: int
    epub_word_count: int
    cached_word_count: int
    text_hash: str
    is_valid: bool
    cached_text_hash: Optional[str] = None
    error_message: Optional[str] = None
    char_diff: int = 0
    char_diff_percent: float = 0.0


@dataclass
class TextIntegrityReport:
    """Complete integrity validation report"""

    total_chapters: int
    valid_chapters: int
    invalid_chapters: int
    chapters_with_issues: List[ChapterTextValidation]
    has_cache_corruption: bool
    cache_engine_mismatch: bool
    errors: List[str]


class TextIntegrityValidator:
    """Validates text integrity before and during conversion"""

    MAX_CHAR_DIFF_PERCENT = 5.0  # Maximum 5% character difference is acceptable
    MIN_CHAR_DIFF_THRESHOLD = 50  # Ignore differences < 50 chars

    def __init__(self, cache_dir: Path, verbose: bool = False):
        self.cache_dir = cache_dir
        self.verbose = verbose

    def normalize_text(self, text: str) -> str:
        """Normalize text for comparison"""
        # Remove extra whitespace
        text = re.sub(r"\s+", " ", text)
        # Remove leading/trailing whitespace
        text = text.strip()
        return text

    def count_words(self, text: str) -> int:
        """Count words in text"""
        return len(re.findall(r"\b\w+\b", text))

    def calculate_text_hash(self, text: str) -> str:
        """Calculate MD5 hash of normalized text"""
        normalized = self.normalize_text(text)
        return hashlib.md5(normalized.encode("utf-8")).hexdigest()

    def get_parsed_text_path(self, chapter_index: int, chapter_title: str) -> Path:
        """Get path to parsed text file for a chapter"""
        text_dir = self.cache_dir / "text"
        text_dir.mkdir(parents=True, exist_ok=True)

        # Sanitize filename
        safe_title = re.sub(r'[<>:"/\\|?*]', "", chapter_title)
        safe_title = safe_title[:100]  # Limit length

        return text_dir / f"{chapter_index} - {safe_title}-parsed.txt"

    def save_parsed_text(self, chapter: Chapter, chapter_index: int) -> Path:
        """Save chapter's parsed text to cache"""
        # Get text from chapter
        text = chapter.text
        if not text:
            text = ""

        # Get file path
        parsed_path = self.get_parsed_text_path(chapter_index, chapter.name)

        # Save text
        parsed_path.write_text(text, encoding="utf-8")

        if self.verbose:
            print(
                f"   💾 Saved parsed text: {parsed_path.name} ({len(text)} chars, {self.count_words(text)} words)"
            )

        return parsed_path

    def load_parsed_text(self, chapter_index: int, chapter_title: str) -> Optional[str]:
        """Load parsed text from cache if it exists"""
        parsed_path = self.get_parsed_text_path(chapter_index, chapter_title)

        if not parsed_path.exists():
            return None

        try:
            return parsed_path.read_text(encoding="utf-8")
        except OSError:
            return None

    def validate_chapter_text(self, chapter: Chapter, chapter_index: int) -> ChapterTextValidation:
        """Validate a single chapter's text against cached version"""
        # Get EPUB text
        epub_text = chapter.speech_text if chapter.speech_text else chapter.text
        if not epub_text:
            epub_text = ""

        epub_text_normalized = self.normalize_text(epub_text)
        epub_char_count = len(epub_text_normalized)
        epub_word_count = self.count_words(epub_text_normalized)
        text_hash = self.calculate_text_hash(epub_text)

        # Try to load cached text first to check if text was lost
        cached_text = self.load_parsed_text(chapter_index, chapter.name)

        # If EPUB has 0 chars, only fail if cache has text (indicating text was lost)
        if epub_char_count == 0:
            if cached_text is not None:
                cached_text_normalized = self.normalize_text(cached_text)
                cached_char_count = len(cached_text_normalized)

                # If cache has text but EPUB doesn't, that's a problem
                if cached_char_count > 0:
                    return ChapterTextValidation(
                        chapter_index=chapter_index,
                        chapter_title=chapter.name,
                        epub_char_count=epub_char_count,
                        cached_char_count=cached_char_count,
                        epub_word_count=epub_word_count,
                        cached_word_count=self.count_words(cached_text_normalized),
                        text_hash=text_hash,
                        cached_text_hash=self.calculate_text_hash(cached_text),
                        is_valid=False,
                        error_message="Chapter text empty in EPUB but present in cache (text was lost)",
                    )

            # EPUB has 0 chars and cache also has 0 chars (or no cache) - this is valid
            # (legitimately empty chapters like cover pages)
            return ChapterTextValidation(
                chapter_index=chapter_index,
                chapter_title=chapter.name,
                epub_char_count=epub_char_count,
                cached_char_count=len(self.normalize_text(cached_text)) if cached_text else 0,
                epub_word_count=epub_word_count,
                cached_word_count=self.count_words(cached_text) if cached_text else 0,
                text_hash=text_hash,
                cached_text_hash=self.calculate_text_hash(cached_text) if cached_text else None,
                is_valid=True,
                error_message=None,
            )

        if cached_text is None:
            # No cache yet - this is OK
            return ChapterTextValidation(
                chapter_index=chapter_index,
                chapter_title=chapter.name,
                epub_char_count=epub_char_count,
                cached_char_count=0,
                epub_word_count=epub_word_count,
                cached_word_count=0,
                text_hash=text_hash,
                cached_text_hash=None,
                is_valid=True,
                error_message=None,
            )

        # Compare with cached text
        cached_text_normalized = self.normalize_text(cached_text)
        cached_char_count = len(cached_text_normalized)
        cached_word_count = self.count_words(cached_text_normalized)
        cached_text_hash = self.calculate_text_hash(cached_text)

        char_diff = epub_char_count - cached_char_count
        char_diff_percent = (
            (abs(char_diff) / max(epub_char_count, 1)) * 100 if epub_char_count > 0 else 0
        )

        # Check if difference is acceptable
        is_valid = True
        error_message = None

        if cached_text_hash != text_hash:
            is_valid = False
            error_message = "Cached text content hash differs from EPUB text"

        if abs(char_diff) > self.MIN_CHAR_DIFF_THRESHOLD:
            if char_diff_percent > self.MAX_CHAR_DIFF_PERCENT:
                is_valid = False
                error_message = (
                    f"Character count mismatch: EPUB has {epub_char_count} chars, "
                    f"cache has {cached_char_count} chars ({char_diff:+d}, {char_diff_percent:.1f}% diff)"
                )

        return ChapterTextValidation(
            chapter_index=chapter_index,
            chapter_title=chapter.name,
            epub_char_count=epub_char_count,
            cached_char_count=cached_char_count,
            epub_word_count=epub_word_count,
            cached_word_count=cached_word_count,
            text_hash=text_hash,
            cached_text_hash=cached_text_hash,
            is_valid=is_valid,
            error_message=error_message,
            char_diff=char_diff,
            char_diff_percent=char_diff_percent,
        )

    def validate_all_chapters(
        self, chapters: List[Chapter], show_progress: bool = True
    ) -> TextIntegrityReport:
        """Validate all chapters and detect cache corruption"""
        if show_progress:
            print("\n" + "=" * 70)
            print("🔍 TEXT INTEGRITY VALIDATION")
            print("=" * 70)
            print("Checking if cache matches current EPUB...\n")

        validations: List[ChapterTextValidation] = []
        has_cache_corruption = False
        errors: List[str] = []
        validation_map: Dict[int, ChapterTextValidation] = {}

        for idx, chapter in enumerate(chapters, start=1):
            validation = self.validate_chapter_text(chapter, idx)
            validations.append(validation)
            validation_map[idx] = validation

            if not validation.is_valid:
                has_cache_corruption = True
                errors.append(f"Chapter {idx} '{chapter.name}': {validation.error_message}")

                if show_progress:
                    print(
                        f"❌ Chapter {idx:3d}: {chapter.name[:50]:50s} | "
                        f"EPUB: {validation.epub_char_count:6d} chars | "
                        f"Cache: {validation.cached_char_count:6d} chars | "
                        f"Diff: {validation.char_diff:+6d} ({validation.char_diff_percent:+5.1f}%)"
                    )
            else:
                if validation.cached_char_count > 0:
                    if show_progress and self.verbose:
                        print(
                            f"✅ Chapter {idx:3d}: {chapter.name[:50]:50s} | "
                            f"{validation.epub_char_count:6d} chars | Cache OK"
                        )
                else:
                    if show_progress and self.verbose:
                        print(
                            f"🆕 Chapter {idx:3d}: {chapter.name[:50]:50s} | "
                            f"{validation.epub_char_count:6d} chars | No cache"
                        )

        # Detect duplicated content across chapters (cached or EPUB)
        # Skip empty chapters - multiple empty chapters are normal (cover pages, etc.)
        hash_to_chapters: Dict[str, List[int]] = {}
        for validation in validations:
            # Skip empty chapters
            if validation.epub_char_count == 0 and validation.cached_char_count == 0:
                continue

            effective_hash = validation.cached_text_hash or validation.text_hash
            if not effective_hash:
                continue
            hash_to_chapters.setdefault(effective_hash, []).append(validation.chapter_index)

        duplicate_groups = [indices for indices in hash_to_chapters.values() if len(indices) > 1]
        duplicate_indices: set[int] = set()

        if duplicate_groups:
            has_cache_corruption = True
            for group in duplicate_groups:
                duplicate_indices.update(group)
                chapter_labels = ", ".join(
                    f"{idx}:{chapters[idx-1].name}" for idx in group if 0 < idx <= len(chapters)
                )
                errors.append(f"Duplicate content detected between chapters: {chapter_labels}")

            if show_progress:
                print("\n⚠️  Duplicate content detected between chapters!")
                for group in duplicate_groups:
                    labels = ", ".join(
                        f"{idx}:{chapters[idx-1].name}" for idx in group if 0 < idx <= len(chapters)
                    )
                    print(f"   → {labels}")

            # Mark duplicates as invalid to force cache refresh
            for dup_idx in duplicate_indices:
                validation = validation_map.get(dup_idx)
                if validation:
                    validation.is_valid = False
                    if not validation.error_message:
                        validation.error_message = "Conteúdo duplicado detectado"

        # Check if cache is from different engine
        cache_engine_mismatch = self._detect_engine_mismatch()

        valid_chapters = sum(1 for v in validations if v.is_valid)
        invalid_chapters = len(validations) - valid_chapters

        if show_progress:
            print("\n" + "=" * 70)
            print("📊 VALIDATION SUMMARY")
            print("=" * 70)
            print(f"Total chapters: {len(chapters)}")
            print(f"✅ Valid chapters: {valid_chapters}")
            print(f"❌ Chapters with issues: {invalid_chapters}")

            if has_cache_corruption:
                print("\n⚠️  ATENÇÃO: Cache corrompido detectado!")
                print("O texto em cache NÃO corresponde ao EPUB atual.")
                print("Isso pode indicar:")
                print("  • Cache de conversão anterior com engine diferente")
                print("  • EPUB foi modificado após última conversão")
                print("  • Corrupção de dados no cache")

            if cache_engine_mismatch:
                print("\n⚠️  ATENÇÃO: Cache de engine diferente detectado!")
                print("O cache parece ser de uma conversão anterior com outra engine.")

            print("=" * 70 + "\n")

        return TextIntegrityReport(
            total_chapters=len(chapters),
            valid_chapters=valid_chapters,
            invalid_chapters=invalid_chapters,
            chapters_with_issues=[v for v in validations if not v.is_valid],
            has_cache_corruption=has_cache_corruption,
            cache_engine_mismatch=cache_engine_mismatch,
            errors=errors,
        )

    def _detect_engine_mismatch(self) -> bool:
        """Detect if cache is from a different TTS engine"""
        # Check if cache has subdirectories like "edge", "kokoro", "coqui"
        if not self.cache_dir.exists():
            return False

        engine_dirs = ["edge", "kokoro", "coqui", "piper", "spark"]
        for engine_dir in engine_dirs:
            if (self.cache_dir / engine_dir).exists():
                return True

        return False

    def save_all_chapters_text(
        self, chapters: List[Chapter], show_progress: bool = True
    ) -> Dict[int, Path]:
        """Save parsed text for all chapters to cache"""
        if show_progress:
            print("\n💾 Saving parsed texts to cache...")

        saved_files: Dict[int, Path] = {}

        for idx, chapter in enumerate(chapters, start=1):
            parsed_path = self.save_parsed_text(chapter, idx)
            saved_files[idx] = parsed_path

        if show_progress:
            print(f"   ✅ {len(saved_files)} text file(s) saved\n")

        return saved_files

    def print_chapter_summary(self, chapters: List[Chapter]) -> None:
        """Print summary of all chapters with character counts"""
        print("\n" + "=" * 100)
        print("📚 CHAPTERS SUMMARY")
        print("=" * 100)
        print(f"{'#':<4} {'Title':<60} {'Chars':>8} {'Words':>10}")
        print("-" * 100)

        total_chars = 0
        total_words = 0

        for idx, chapter in enumerate(chapters, start=1):
            text = chapter.speech_text if chapter.speech_text else chapter.text
            if not text:
                text = ""

            normalized = self.normalize_text(text)
            char_count = len(normalized)
            word_count = self.count_words(normalized)

            total_chars += char_count
            total_words += word_count

            print(f"{idx:<4} {chapter.name[:60]:<60} {char_count:>8,} {word_count:>10,}")

        print("-" * 100)
        print(f"{'TOTAL':<64} {total_chars:>8,} {total_words:>10,}")
        print("=" * 100 + "\n")
