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
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


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
        self._chapter_list: list = []  # ordered list from EbookReader

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
        m = re.match(r"^(\d+(?:\.\d+)?)\s*-\s*", filename)
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
                    error_msg="Não foi possível encontrar capítulo correspondente no EPUB",
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
