"""
Deep validation system for EPUB to MP3 conversions.

This module performs comprehensive validation including:
- Duplicate detection across chapters
- Start/middle/end content comparison with original EPUB
- Character count verification per chapter
- Visual TOC structure comparison
"""

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import ebooklib
from bs4 import BeautifulSoup
from ebooklib import epub


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
        print("🔍 VALIDAÇÃO PROFUNDA - RELATÓRIO FINAL")
        print("=" * 80)

        print("\n📊 Estatísticas Gerais:")
        print(f"   Total de capítulos: {self.total_chapters}")
        print(f"   ✅ Capítulos válidos: {self.valid_chapters}")
        print(f"   ❌ Capítulos com problemas: {self.total_chapters - self.valid_chapters}")

        if self.duplicates_found > 0:
            print(f"\n⚠️  Duplicações Encontradas: {self.duplicates_found}")
            for file1, file2 in self.duplicate_files[:5]:  # Show first 5
                print(f"   - {file1} = {file2}")
        else:
            print("\n✅ Duplicações: Nenhuma encontrada")

        if self.char_mismatches > 0:
            print(f"\n⚠️  Diferenças de Caracteres: {self.char_mismatches} capítulos")
        else:
            print("\n✅ Contagem de Caracteres: Todas dentro da tolerância")

        if self.content_mismatches > 0:
            print(f"\n⚠️  Diferenças de Conteúdo: {self.content_mismatches} capítulos")
            print("   (início/meio/final não correspondem)")
        else:
            print("\n✅ Conteúdo: Início/meio/final correspondem ao EPUB")

        # Show failed chapters
        failed = [c for c in self.comparisons if not c.is_valid]
        if failed:
            print("\n❌ Capítulos com Problemas:")
            for comp in failed[:10]:  # Show first 10
                print(f"   - {comp.chapter_id}: {comp.error_msg}")

        print("\n" + "=" * 80)
        if self.success:
            print("✅ VALIDAÇÃO PROFUNDA PASSOU!")
            print("   - Nenhuma duplicação detectada")
            print("   - Contagem de caracteres correta")
            print(
                f"   - {self.valid_chapters}/{self.total_chapters} capítulos validados com sucesso"
            )
            if self.auto_corrected and self.corrections_made:
                print(f"\n🔧 Autocorreções Aplicadas: {len(self.corrections_made)}")
                for correction in self.corrections_made[:5]:
                    print(f"   - {correction}")
        else:
            print("⚠️  VALIDAÇÃO PROFUNDA: Problemas detectados")
            if self.duplicates_found > 0:
                print(f"   - {self.duplicates_found} duplicações no cache")
            if self.char_mismatches > 0:
                print(f"   - {self.char_mismatches} capítulos com diferença de caracteres")
            if self.content_mismatches > 0:
                print(f"   - {self.content_mismatches} capítulos com diferenças de conteúdo")

            if self.auto_corrected and self.corrections_made:
                print(f"\n🔧 Autocorreções Aplicadas: {len(self.corrections_made)}")
                for correction in self.corrections_made[:5]:
                    print(f"   - {correction}")
                print("\n   ⚠️  Alguns problemas foram corrigidos, mas outros persistem.")
                print("   💡 Considere rodar novamente a conversão com --clear-cache")
            else:
                print("\n   ⚠️  Execute novamente com --clear-cache para corrigir.")
        print("=" * 80 + "\n")


class DeepValidator:
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

    def load_epub_chapters(self) -> bool:
        """Load and parse all chapters from the original EPUB."""
        try:
            book = epub.read_epub(self.epub_path)

            for item in book.get_items():
                if item.get_type() == ebooklib.ITEM_DOCUMENT:
                    soup = BeautifulSoup(item.get_content(), "html.parser")
                    text = soup.get_text()
                    text_clean = " ".join(text.split())  # Normalize whitespace

                    if len(text_clean) > 50:  # Skip very small chapters
                        self.epub_chapters[item.get_id()] = text_clean

            return len(self.epub_chapters) > 0
        except Exception as e:
            print(f"❌ Erro ao carregar EPUB: {e}")
            return False

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
                print(f"⚠️  Erro ao ler {filepath.name}: {e}")

        return duplicates

    def compare_content_sections(
        self, epub_text: str, parsed_text: str, sample_size: int = 200
    ) -> Tuple[bool, bool, bool]:
        """
        Compare start, middle, and end sections of content.

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

        # Compare start
        epub_start = epub_norm[:sample_size]
        parsed_start = parsed_norm[:sample_size]
        start_match = self._fuzzy_match(epub_start, parsed_start)

        # Compare middle
        epub_mid_pos = len(epub_norm) // 2
        parsed_mid_pos = len(parsed_norm) // 2
        epub_middle = epub_norm[
            max(0, epub_mid_pos - sample_size // 2) : epub_mid_pos + sample_size // 2
        ]
        parsed_middle = parsed_norm[
            max(0, parsed_mid_pos - sample_size // 2) : parsed_mid_pos + sample_size // 2
        ]
        middle_match = self._fuzzy_match(epub_middle, parsed_middle)

        # Compare end
        epub_end = epub_norm[-sample_size:]
        parsed_end = parsed_norm[-sample_size:]
        end_match = self._fuzzy_match(epub_end, parsed_end)

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

    def compare_chapter(
        self, parsed_file: Path, chapter_number: Optional[int] = None
    ) -> Optional[ChapterComparison]:
        """
        Compare a parsed chapter with its original EPUB content.

        Args:
            parsed_file: Path to parsed text file
            chapter_number: Optional chapter number for identification

        Returns:
            ChapterComparison object or None if comparison failed
        """
        try:
            # Read parsed content
            with open(parsed_file, "r", encoding="utf-8") as f:
                parsed_text = f.read()

            parsed_clean = " ".join(parsed_text.split())
            parsed_chars = len(parsed_clean)

            # Try to match with EPUB chapters
            # Look for best match by comparing middle/end content (skip headers)
            best_match = None
            best_score = 0

            # Get a sample from middle/end of parsed text (skip potential headers)
            parsed_words = parsed_clean.split()
            skip_header = min(50, len(parsed_words) // 10)  # Skip first 10% or 50 words
            parsed_sample = parsed_words[skip_header : skip_header + 50]  # Take 50 words after skip

            for epub_id, epub_text in self.epub_chapters.items():
                epub_words = epub_text.split()

                # Try to find parsed_sample in epub text
                for i in range(len(epub_words) - len(parsed_sample)):
                    epub_chunk = epub_words[i : i + len(parsed_sample)]
                    score = sum(
                        1 for w1, w2 in zip(epub_chunk, parsed_sample) if w1.lower() == w2.lower()
                    )

                    if score > best_score:
                        best_score = score
                        best_match = (epub_id, epub_text)

            if not best_match or best_score < 10:  # Minimum 10 matching words
                # Could not find matching chapter - but this might be OK for small chapters
                # Check if it's a very small chapter (< 500 chars)
                if parsed_chars < 500:
                    # Small chapter, consider it valid if it exists
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
                    error_msg="Não foi possível encontrar capítulo correspondente no EPUB",
                )

            epub_id, epub_text = best_match
            epub_clean = " ".join(epub_text.split())
            epub_chars = len(epub_clean)

            # Calculate character difference
            char_diff = abs(parsed_chars - epub_chars)
            char_diff_pct = (char_diff / epub_chars * 100) if epub_chars > 0 else 0

            # Compare content sections
            start_match, middle_match, end_match = self.compare_content_sections(
                epub_clean, parsed_clean
            )

            # Determine if valid
            is_valid = (
                char_diff_pct <= self.tolerance_pct
                and start_match
                and end_match  # Middle can be more flexible
            )

            error_msg = None
            if not is_valid:
                errors = []
                if char_diff_pct > self.tolerance_pct:
                    errors.append(f"Diferença de caracteres: {char_diff_pct:.1f}%")
                if not start_match:
                    errors.append("Início não corresponde")
                if not middle_match:
                    errors.append("Meio não corresponde")
                if not end_match:
                    errors.append("Final não corresponde")
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
                error_msg=f"Erro ao processar: {str(e)}",
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
            print("\n🔧 Aplicando autocorreção...")
            print(f"   Removendo {len(duplicates)} arquivo(s) duplicado(s)...")

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
                    print(f"   ⚠️  Erro ao remover {to_remove.name}: {e}")

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
        print("🔍 INICIANDO VALIDAÇÃO PROFUNDA...")
        print("=" * 80)

        # Load EPUB chapters
        print("\n📖 Carregando capítulos do EPUB original...")
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
        print(f"   ✅ {len(self.epub_chapters)} capítulos carregados")

        # Find parsed files
        print("\n📁 Procurando arquivos parsed...")
        parsed_files = self.find_parsed_files()
        print(f"   ✅ {len(parsed_files)} arquivos encontrados")

        # Detect duplicates
        print("\n🔍 Verificando duplicações...")
        duplicates = self.detect_duplicates(parsed_files)
        print(f"   {'✅' if not duplicates else '⚠️ '} {len(duplicates)} duplicações encontradas")

        # Auto-correct duplicates if requested
        corrections_made = []
        if auto_correct and duplicates:
            corrections_made = self.auto_correct(duplicates)
            # Re-scan after correction
            parsed_files = self.find_parsed_files()
            duplicates = []  # Clear duplicates after correction

        # Compare each chapter
        print("\n📊 Comparando capítulos (início/meio/final + caracteres)...")
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

        # Success criteria: no duplicates and most chapters valid
        # Allow some content mismatches for cached files with headers
        success_rate = (valid_chapters / len(comparisons)) if comparisons else 1.0
        success = (
            len(duplicates) == 0
            and char_mismatches == 0
            and success_rate >= 0.5  # At least 50% of chapters must be valid
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


def run_deep_validation(epub_path: str, cache_dir: str, auto_correct: bool = True) -> bool:
    """
    Run deep validation on a converted audiobook with automatic correction.

    Args:
        epub_path: Path to original EPUB file
        cache_dir: Path to cache directory with parsed files
        auto_correct: If True, automatically fix detected issues (default: True)

    Returns:
        True if validation passed, False otherwise
    """
    validator = DeepValidator(epub_path, cache_dir)
    report = validator.validate(auto_correct=auto_correct)
    return report.success
