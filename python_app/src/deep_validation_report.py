"""Structured chapter comparisons and the complete deep-validation report."""

from dataclasses import dataclass
from typing import List, Optional, Tuple


@dataclass
class ChapterComparison:
    """Comparison result for a single chapter."""

    chapter_id: str
    epub_chars: int
    parsed_chars: int
    char_diff_pct: float
    start_match: bool
    middle_match: bool
    end_match: bool
    is_valid: bool
    error_msg: Optional[str] = None


@dataclass
class ValidationReport:
    """Complete validation report."""

    total_chapters: int
    valid_chapters: int
    duplicates_found: int
    char_mismatches: int
    content_mismatches: int
    comparisons: List[ChapterComparison]
    duplicate_files: List[Tuple[str, str]]
    success: bool
    auto_corrected: bool = False
    corrections_made: List[str] = None

    def __post_init__(self):
        if self.corrections_made is None:
            self.corrections_made = []

    def print_summary(self):
        """Print a formatted summary of the validation."""
        print("\n" + "=" * 80)
        print("🔍 DEEP VALIDATION - FINAL REPORT")
        print("=" * 80)

        print("\n📊 General Statistics:")
        print(f"   Total chapters: {self.total_chapters}")
        print(f"   ✅ Valid chapters: {self.valid_chapters}")
        print(f"   ❌ Chapters with issues: {self.total_chapters - self.valid_chapters}")

        if self.duplicates_found > 0:
            print(f"\n⚠️  Duplications Found: {self.duplicates_found}")
            for file1, file2 in self.duplicate_files[:5]:  # Show first 5
                print(f"   - {file1} = {file2}")
        else:
            print("\n✅ Duplications: None found")

        if self.char_mismatches > 0:
            print(f"\n⚠️  Character Differences: {self.char_mismatches} chapters")
        else:
            print("\n✅ Character Count: All within tolerance")

        if self.content_mismatches > 0:
            print(f"\n⚠️  Content Differences: {self.content_mismatches} chapters")
            print("   (start/middle/end do not match)")
        else:
            print("\n✅ Content: Start/middle/end match the EPUB")

        # Show failed chapters
        failed = [c for c in self.comparisons if not c.is_valid]
        if failed:
            print("\n❌ Chapters with Issues:")
            for comp in failed[:10]:  # Show first 10
                print(f"   - {comp.chapter_id}: {comp.error_msg}")

        print("\n" + "=" * 80)
        if self.success:
            print("✅ DEEP VALIDATION PASSED!")
            print("   - No duplications detected")
            print("   - Character count correct")
            print(
                f"   - {self.valid_chapters}/{self.total_chapters} chapters validated successfully"
            )
            if self.auto_corrected and self.corrections_made:
                print(f"\n🔧 Auto-corrections Applied: {len(self.corrections_made)}")
                for correction in self.corrections_made[:5]:
                    print(f"   - {correction}")
        else:
            print("⚠️  DEEP VALIDATION: Issues detected")
            if self.duplicates_found > 0:
                print(f"   - {self.duplicates_found} duplications in cache")
            if self.char_mismatches > 0:
                print(f"   - {self.char_mismatches} chapters with character differences")
            if self.content_mismatches > 0:
                print(f"   - {self.content_mismatches} chapters with content differences")

            if self.auto_corrected and self.corrections_made:
                print(f"\n🔧 Auto-corrections Applied: {len(self.corrections_made)}")
                for correction in self.corrections_made[:5]:
                    print(f"   - {correction}")
                print("\n   ⚠️  Some issues were corrected, but others persist.")
                print("   💡 Consider running the conversion again with --clear-cache")
            else:
                print("\n   ⚠️  Run again with --clear-cache to fix.")
        print("=" * 80 + "\n")
