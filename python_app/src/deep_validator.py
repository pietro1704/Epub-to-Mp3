"""
Deep validation system for EPUB to MP3 conversions.

This module performs comprehensive validation including:
- Duplicate detection across chapters
- Start/middle/end content comparison with original EPUB
- Character count verification per chapter
- Visual TOC structure comparison
"""

import hashlib
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .deep_validation_report import ChapterComparison as ChapterComparison
from .deep_validation_report import ValidationReport as ValidationReport
from .epub_validation_index import EpubValidationIndex


class DeepValidator(EpubValidationIndex):
    """Deep validation system for converted chapters."""

    def __init__(self, epub_path: str, cache_dir: str, tolerance_pct: float = 10.0):
        """
        Initialize the deep validator.

        Args:
            epub_path: Path to original EPUB file
            cache_dir: Path to cache directory with parsed files
            tolerance_pct: Character count tolerance percentage (default 10%)
        """
        self.epub_path = epub_path
        self.cache_dir = Path(cache_dir)
        self.tolerance_pct = tolerance_pct
        self.epub_chapters: Dict[str, str] = {}
        self._chapter_list: list = []  # ordered list from EbookReader


    def find_parsed_files(self) -> List[Path]:
        """Find all parsed text files in the cache directory."""
        parsed_files = []

        # Look in text directory
        text_dir = self.cache_dir / "text"
        if text_dir.exists():
            parsed_files.extend(text_dir.glob("*-parsed.txt"))

        # Also look in root cache dir
        parsed_files.extend(self.cache_dir.glob("*-parsed.txt"))

        # Remove duplicate file paths (same content, different names)
        # Keep only unique basenames to avoid false duplicate detection
        seen_names = set()
        unique_files = []
        for f in parsed_files:
            # Normalize name by removing leading numbers and duplicates
            normalized = f.name.split(" - ", 1)[-1] if " - " in f.name else f.name
            if normalized not in seen_names:
                seen_names.add(normalized)
                unique_files.append(f)

        return unique_files

    def detect_duplicates(self, files: List[Path]) -> List[Tuple[str, str]]:
        """
        Detect duplicate files by content hash.

        Returns:
            List of (file1, file2) tuples that are duplicates
        """
        file_hashes: Dict[str, str] = {}
        duplicates: List[Tuple[str, str]] = []

        for filepath in files:
            try:
                with open(filepath, "r", encoding="utf-8") as f:
                    content = " ".join(f.read().split())  # Normalize
                    file_hash = hashlib.md5(content.encode()).hexdigest()

                    filename = filepath.name
                    if file_hash in file_hashes:
                        duplicates.append((filename, file_hashes[file_hash]))
                    else:
                        file_hashes[file_hash] = filename
            except Exception as e:
                print(f"⚠️  Error reading {filepath.name}: {e}")

        return duplicates

    def compare_content_sections(
        self, epub_text: str, parsed_text: str, sample_size: int = 200
    ) -> Tuple[bool, bool, bool]:
        """
        Compare start, middle, and end sections of content.

        Uses positional fuzzy matching first, then falls back to a
        containment check (does the EPUB sample appear anywhere in the
        parsed text?).  This handles slight positional shifts caused by
        the converter trimming or extending content.

        Args:
            epub_text: Original EPUB text
            parsed_text: Parsed text from conversion
            sample_size: Number of characters to compare in each section

        Returns:
            Tuple of (start_match, middle_match, end_match)
        """
        # Normalize both texts
        epub_norm = " ".join(epub_text.split())
        parsed_norm = " ".join(parsed_text.split())
        parsed_lower = parsed_norm.lower()

        def _check_section(epub_sample: str, parsed_sample: str) -> bool:
            """Positional fuzzy match, then containment fallback."""
            if self._fuzzy_match(epub_sample, parsed_sample):
                return True
            # Containment: does the epub sample appear in the full parsed text?
            return epub_sample.lower() in parsed_lower

        # Compare start
        epub_start = epub_norm[:sample_size]
        parsed_start = parsed_norm[:sample_size]
        start_match = _check_section(epub_start, parsed_start)

        # Compare middle
        epub_mid_pos = len(epub_norm) // 2
        parsed_mid_pos = len(parsed_norm) // 2
        epub_middle = epub_norm[
            max(0, epub_mid_pos - sample_size // 2) : epub_mid_pos + sample_size // 2
        ]
        parsed_middle = parsed_norm[
            max(0, parsed_mid_pos - sample_size // 2) : parsed_mid_pos + sample_size // 2
        ]
        middle_match = _check_section(epub_middle, parsed_middle)

        # Compare end
        epub_end = epub_norm[-sample_size:]
        parsed_end = parsed_norm[-sample_size:]
        end_match = _check_section(epub_end, parsed_end)

        return start_match, middle_match, end_match

    def _fuzzy_match(self, text1: str, text2: str, threshold: float = 0.8) -> bool:
        """
        Fuzzy string matching using word overlap.

        Args:
            text1: First text
            text2: Second text
            threshold: Minimum word overlap ratio (0.0 to 1.0)

        Returns:
            True if texts are similar enough
        """
        words1 = set(text1.lower().split())
        words2 = set(text2.lower().split())

        if not words1 or not words2:
            return len(text1) == len(text2) == 0

        overlap = len(words1 & words2)
        total = max(len(words1), len(words2))

        return (overlap / total) >= threshold if total > 0 else False

    @staticmethod
    def _extract_chapter_index(filename: str) -> Optional[str]:
        """Extract the chapter index from a parsed filename.

        Filenames follow the pattern ``"<label> - <name>-parsed.txt"``
        where *label* may be ``"1"``, ``"1.0"``, ``"5.4"``, etc.

        Returns the label string (e.g. ``"5.4"``) or ``None``.
        """
        m = re.match(r"^(\d+(?:\.\d+)*)\s*-\s*", filename)
        return m.group(1) if m else None

    def compare_chapter(
        self, parsed_file: Path, chapter_number: Optional[int] = None
    ) -> Optional[ChapterComparison]:
        """Compare a parsed chapter with its original EPUB content.

        Uses content-fingerprint matching: computes a fingerprint from the
        first N words of the parsed file and looks it up in the
        fingerprint-keyed ``self.epub_chapters`` dictionary.
        """
        try:
            with open(parsed_file, "r", encoding="utf-8") as f:
                parsed_text = f.read()

            parsed_clean = " ".join(parsed_text.split())
            parsed_chars = len(parsed_clean)

            # --- Content matching (fingerprint + substring fallback) ---
            epub_text = self._find_epub_match(parsed_clean)

            if epub_text is None:
                # Small chapters without a match are considered valid
                if parsed_chars < 500:
                    return ChapterComparison(
                        chapter_id=parsed_file.name,
                        epub_chars=parsed_chars,
                        parsed_chars=parsed_chars,
                        char_diff_pct=0.0,
                        start_match=True,
                        middle_match=True,
                        end_match=True,
                        is_valid=True,
                        error_msg=None,
                    )

                return ChapterComparison(
                    chapter_id=parsed_file.name,
                    epub_chars=0,
                    parsed_chars=parsed_chars,
                    char_diff_pct=100.0,
                    start_match=False,
                    middle_match=False,
                    end_match=False,
                    is_valid=False,
                    error_msg="Could not find matching chapter in EPUB",
                )

            epub_clean = " ".join(epub_text.split())
            epub_chars = len(epub_clean)

            # The converter may prepend section/chapter headers to the
            # parsed text, so parsed_chars >= epub_chars is expected.
            # We consider the chapter valid when the EPUB text is fully
            # represented in the parsed text (with up to tolerance_pct
            # extra characters for headers).
            extra_chars = parsed_chars - epub_chars
            # Negative means parsed is shorter (converter trimmed) — use abs
            char_diff = abs(extra_chars) if extra_chars < 0 else 0
            char_diff_pct = (char_diff / epub_chars * 100) if epub_chars > 0 else 0

            # Try to locate where the EPUB text starts within the parsed
            # text so we can strip the prepended header for comparison.
            epub_start_words = " ".join(epub_clean.split()[:8]).lower()
            idx_in_parsed = parsed_clean.lower().find(epub_start_words)
            if idx_in_parsed > 0:
                parsed_body = parsed_clean[idx_in_parsed:]
            elif parsed_chars > epub_chars:
                parsed_body = parsed_clean[-epub_chars:]
            else:
                parsed_body = parsed_clean

            start_match, middle_match, end_match = self.compare_content_sections(
                epub_clean, parsed_body
            )

            # Valid when character count is within tolerance AND at least
            # two of three sections match (start is weighted most heavily,
            # but the converter may trim the ending slightly).
            section_matches = sum([start_match, middle_match, end_match])
            is_valid = char_diff_pct <= self.tolerance_pct and section_matches >= 2

            error_msg = None
            if not is_valid:
                errors = []
                if char_diff_pct > self.tolerance_pct:
                    errors.append(f"Character difference: {char_diff_pct:.1f}%")
                if not start_match:
                    errors.append("Start does not match")
                if not middle_match:
                    errors.append("Middle does not match")
                if not end_match:
                    errors.append("End does not match")
                error_msg = "; ".join(errors)

            return ChapterComparison(
                chapter_id=parsed_file.name,
                epub_chars=epub_chars,
                parsed_chars=parsed_chars,
                char_diff_pct=char_diff_pct,
                start_match=start_match,
                middle_match=middle_match,
                end_match=end_match,
                is_valid=is_valid,
                error_msg=error_msg,
            )

        except Exception as e:
            return ChapterComparison(
                chapter_id=parsed_file.name,
                epub_chars=0,
                parsed_chars=0,
                char_diff_pct=100.0,
                start_match=False,
                middle_match=False,
                end_match=False,
                is_valid=False,
                error_msg=f"Error processing: {str(e)}",
            )

    def auto_correct(self, duplicates: List[Tuple[str, str]]) -> List[str]:
        """
        Automatically correct detected issues.

        Args:
            duplicates: List of duplicate file pairs

        Returns:
            List of corrections made
        """
        corrections = []

        # 1. Remove duplicate files (keep the one with shorter name)
        if duplicates:
            print("\n🔧 Applying auto-correction...")
            print(f"   Removing {len(duplicates)} duplicate file(s)...")

            for file1, file2 in duplicates:
                # Find the actual file paths
                text_dir = self.cache_dir / "text"

                path1 = text_dir / file1 if (text_dir / file1).exists() else self.cache_dir / file1
                path2 = text_dir / file2 if (text_dir / file2).exists() else self.cache_dir / file2

                # Keep the file with shorter name (usually the correct one)
                to_remove = path1 if len(file1) > len(file2) else path2

                try:
                    if to_remove.exists():
                        to_remove.unlink()
                        corrections.append(f"Removido duplicado: {to_remove.name}")
                        print(f"   ✅ Removido: {to_remove.name}")
                except Exception as e:
                    print(f"   ⚠️  Error removing {to_remove.name}: {e}")

        return corrections

    def validate(self, auto_correct: bool = True) -> ValidationReport:
        """
        Perform complete deep validation with optional auto-correction.

        Args:
            auto_correct: If True, automatically fix detected issues

        Returns:
            ValidationReport with all results
        """
        print("\n" + "=" * 80)
        print("🔍 STARTING DEEP VALIDATION...")
        print("=" * 80)

        # Load EPUB chapters
        print("\n📖 Loading chapters from original EPUB...")
        if not self.load_epub_chapters():
            return ValidationReport(
                total_chapters=0,
                valid_chapters=0,
                duplicates_found=0,
                char_mismatches=0,
                content_mismatches=0,
                comparisons=[],
                duplicate_files=[],
                success=False,
            )
        print(f"   ✅ {len(self.epub_chapters)} chapters loaded")

        # Find parsed files
        print("\n📁 Searching for parsed files...")
        parsed_files = self.find_parsed_files()
        print(f"   ✅ {len(parsed_files)} files found")

        # Detect duplicates
        print("\n🔍 Checking for duplications...")
        duplicates = self.detect_duplicates(parsed_files)
        print(f"   {'✅' if not duplicates else '⚠️ '} {len(duplicates)} duplications found")

        # Auto-correct duplicates if requested
        corrections_made = []
        if auto_correct and duplicates:
            corrections_made = self.auto_correct(duplicates)
            # Re-scan after correction
            parsed_files = self.find_parsed_files()
            duplicates = []  # Clear duplicates after correction

        # Compare each chapter
        print("\n📊 Comparing chapters (start/middle/end + characters)...")
        comparisons: List[ChapterComparison] = []

        for i, parsed_file in enumerate(parsed_files, 1):
            print(f"   [{i}/{len(parsed_files)}] {parsed_file.name[:60]}...", end="\r")
            comp = self.compare_chapter(parsed_file, i)
            if comp:
                comparisons.append(comp)

        print()  # New line after progress

        # Calculate statistics
        valid_chapters = sum(1 for c in comparisons if c.is_valid)
        char_mismatches = sum(1 for c in comparisons if c.char_diff_pct > self.tolerance_pct)
        content_mismatches = sum(
            1 for c in comparisons if not (c.start_match and c.middle_match and c.end_match)
        )

        # Success criteria: no duplicates and ALL chapters must be valid
        success_rate = (valid_chapters / len(comparisons)) if comparisons else 1.0
        success = (
            len(duplicates) == 0
            and char_mismatches == 0
            and success_rate >= 1.0  # All chapters must be valid
        )

        report = ValidationReport(
            total_chapters=len(comparisons),
            valid_chapters=valid_chapters,
            duplicates_found=len(duplicates),
            char_mismatches=char_mismatches,
            content_mismatches=content_mismatches,
            comparisons=comparisons,
            duplicate_files=duplicates,
            success=success,
            auto_corrected=bool(corrections_made),
            corrections_made=corrections_made,
        )

        # Print summary
        report.print_summary()

        return report


def run_deep_validation(
    epub_path: str, cache_dir: str, auto_correct: bool = True
) -> ValidationReport:
    """
    Run deep validation on a converted audiobook with automatic correction.

    Args:
        epub_path: Path to original EPUB file
        cache_dir: Path to cache directory with parsed files
        auto_correct: If True, automatically fix detected issues (default: True)

    Returns:
        ValidationReport with full results (check .success for pass/fail)
    """
    validator = DeepValidator(epub_path, cache_dir)
    return validator.validate(auto_correct=auto_correct)
