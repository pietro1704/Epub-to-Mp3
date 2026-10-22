"""Render chapter diagnostics and aggregate whole-book integrity results."""

import os
import re
from pathlib import Path

from conversion_validation_integrity import (
    detect_duplicate_audio_files,
    verify_chapter_names,
    verify_mp3_integrity,
)
from conversion_validation_text import (
    _extract_samples,
    _samples_match,
    _truncate_for_display,
    contains_html_markup,
    normalize_text,
    normalize_title_key,
    strip_formatting_cues,
)


def print_chapter_detail(
    chapter_num: int,
    title: str,
    epub_text: str,
    parsed_text: str | None,
    pretts_text: str | None,
    mp3_file: Path | None,
    validator,
) -> None:
    """Print detailed start/mid/end text comparison for a chapter."""
    epub_norm = normalize_text(epub_text) if epub_text else ""
    parsed_norm = normalize_text(parsed_text) if parsed_text else ""
    pretts_norm = normalize_text(strip_formatting_cues(pretts_text)) if pretts_text else ""

    epub_samples = _extract_samples(epub_text) if epub_text else ("", "", "")
    parsed_samples = _extract_samples(parsed_text) if parsed_text else ("", "", "")
    pretts_samples = _extract_samples(pretts_text) if pretts_text else ("", "", "")

    short_title = _truncate_for_display(title, 60)
    print(f"  📖 Cap {chapter_num} ({short_title}) [{len(epub_norm):,} chars]")

    section_names = ["START", "MIDDLE", "END"]
    connectors = ["├─", "├─", "├─"]

    for i, section in enumerate(section_names):
        epub_s = epub_samples[i]
        parsed_s = parsed_samples[i]
        pretts_s = pretts_samples[i]

        connector = connectors[i]
        print(f"  {connector} {section}:")

        epub_disp = _truncate_for_display(epub_s)
        print(f'  │  EPUB:   "{epub_disp}"')

        if parsed_text:
            parsed_disp = _truncate_for_display(parsed_s)
            p_match = _samples_match(epub_s, parsed_s, parsed_norm)
            print(f'  │  Parsed: "{parsed_disp}"')
        else:
            p_match = False
            print("  │  Parsed: (not found)")

        if pretts_text:
            pretts_disp = _truncate_for_display(pretts_s)
            t_match = _samples_match(epub_s, pretts_s, pretts_norm)
            print(f'  │  PreTTS: "{pretts_disp}"')
        else:
            t_match = True  # No pre-tts to compare
            print("  │  PreTTS: (not found)")

        if p_match and t_match:
            print("  │  Result: ✅ Match")
        elif p_match:
            print("  │  Result: ⚠️  PreTTS diverges")
        elif t_match:
            print("  │  Result: ⚠️  Parsed diverges")
        else:
            print("  │  Result: ❌ Mismatch")

    # MP3 info
    if mp3_file and mp3_file.exists():
        mp3_size_mb = mp3_file.stat().st_size / (1024 * 1024)
        try:
            duration = validator.get_audio_duration(mp3_file)
        except Exception:
            duration = None
        if isinstance(duration, (int, float)) and duration > 0:
            duration_min = duration / 60
            chars_per_min = int(len(epub_norm) / duration_min) if duration_min > 0 else 0
            print(
                f"  └─ 🎵 MP3: {mp3_size_mb:.1f} MB | {duration_min:.1f} min | ~{chars_per_min} chars/min"
            )
        else:
            print(f"  └─ 🎵 MP3: {mp3_size_mb:.1f} MB | duration unavailable")
    else:
        print("  └─ 🎵 MP3: (not found)")
    print()


def print_book_report(stats, issues, text_hashes, epub_chapters, output_dir):
    """Append whole-book issues and print the existing final report."""
    # Summary
    print("\n" + "=" * 70)
    print("📊 VALIDATION SUMMARY")
    print("=" * 70)
    print(f"Total chapters in EPUB: {stats['total_chapters']}")
    print(f"✅ Perfect chapters: {stats['perfect']}")
    if stats["perfect"] > 0:
        print("   → All with Start/Middle/End ✓✓✓ and 100% text (no missing characters)")
    print(f"⚠️  Missing cache: {stats['missing_cache']}")
    print(f"❌ EPUB ≠ Parsed: {stats['text_mismatch']}")
    print(f"⚠️  Parsed ≠ PreTTS: {stats['parsed_pretts_diff']}")
    print(f"❌ Missing MP3: {stats['missing_mp3']}")
    print(f"⚠️  Wrong duration: {stats['duration_mismatch']}")
    print(f"❌ Duplicate audio: {stats['audio_duplicate']}")

    # Check if we should suppress error messages (during auto-fix)
    suppress_errors = os.environ.get("SUPPRESS_VALIDATION_ERRORS", "").lower() == "true"

    if issues and not suppress_errors:
        print("\n" + "=" * 70)
        print("🔥 CRITICAL ISSUES FOUND")
        print("=" * 70)
        for issue in issues:
            print(f"  • {issue}")

    # Duplicate detection
    dup_groups = [ch_list for ch_list in text_hashes.values() if len(ch_list) > 1]
    if dup_groups:
        if not suppress_errors:
            print("\n⚠️  DUPLICATE CONTENT DETECTED BETWEEN CHAPTERS")
            for group in dup_groups:
                print(f"  • Chapters: {', '.join(map(str, group))}")
        stats["text_mismatch"] += len(dup_groups)
        issues.append("Duplicate content detected between chapters")

    audio_dupes = detect_duplicate_audio_files(output_dir)
    if audio_dupes:
        if not suppress_errors:
            print("\n⚠️  DUPLICATE AUDIO DETECTED BETWEEN FILES")
            for group in audio_dupes:
                labels = ", ".join(path.name for path in group)
                print(f"  • Files: {labels}")
        stats["audio_duplicate"] += len(audio_dupes)
        issues.append("Duplicate audio files detected (hash match)")

    # Verify chapter name integrity
    name_issues = verify_chapter_names(epub_chapters, output_dir)
    if name_issues:
        if not suppress_errors:
            print("\n⚠️  CHAPTER NAME ISSUES")
            for ni in name_issues:
                print(f"  • {ni}")
        for ni in name_issues:
            issues.append(f"Chapter name issue: {ni}")

    # Verify MP3 file integrity (headers + size)
    mp3_issues = verify_mp3_integrity(output_dir)
    if mp3_issues:
        if not suppress_errors:
            print("\n⚠️  MP3 INTEGRITY ISSUES")
            for mi in mp3_issues:
                print(f"  • {mi}")
        for mi in mp3_issues:
            issues.append(f"MP3 integrity: {mi}")

    # Validate full book text file
    print("\n" + "=" * 70)
    print("📖 FULL BOOK TEXT VALIDATION")
    print("=" * 70)

    # Support both naming conventions: legacy _completo.txt and current _complete.txt
    full_book_files = list(output_dir.glob("*_completo.txt")) or list(
        output_dir.glob("*_complete.txt")
    )
    if not full_book_files:
        print("⚠️  Complete book text file not found")
        issues.append("Missing complete book text file")
    else:
        full_book_file = full_book_files[0]
        full_text = full_book_file.read_text(encoding="utf-8")
        full_text_norm = normalize_text(full_text)

        # Parse chapter titles from the full-book file to only count converted chapters.
        # Supports both legacy "CAPÍTULO X.Y: title" and current "CHAPTER X.Y: title" headers.
        converted_titles = set()
        for match in re.finditer(
            r"^(?:CAPÍTULO|CHAPTER)\s+\d+(?:\.\d+)?\s*:\s*(.+?)$", full_text, re.MULTILINE
        ):
            title = match.group(1).strip()
            converted_titles.add(normalize_title_key(title))

        # Calculate expected total ONLY from chapters that were actually converted
        if converted_titles:
            total_epub_chars = 0
            for _, chapter_title, text in epub_chapters:
                if not text:
                    continue
                norm_title = normalize_title_key(chapter_title)
                if any(
                    norm_title in conv_title or conv_title in norm_title
                    for conv_title in converted_titles
                ):
                    total_epub_chars += len(normalize_text(text))
        else:
            # Fallback if no chapter headers found - use all chapters (old behavior)
            total_epub_chars = sum(
                len(normalize_text(text)) for _, _, text in epub_chapters if text
            )

        # Strip chapter headers from the file for fair comparison
        # (headers are formatting added by the converter, not EPUB content)
        full_text_without_headers = "\n".join(
            line
            for line in full_text.split("\n")
            if not (
                line.strip().startswith("===")
                or line.strip().startswith("CAPÍTULO")
                or line.strip().startswith("CHAPTER")
            )
        )
        full_book_chars = len(normalize_text(full_text_without_headers))

        print(f"📄 File: {full_book_file.name}")
        print(f"📊 Size: {len(full_text):,} chars ({len(full_text_norm):,} normalized)")
        print(f"📖 EPUB total: {total_epub_chars:,} chars normalized")

        # Check if full text contains HTML
        if contains_html_markup(full_text):
            print("❌ Complete book text contains HTML tags!")
            issues.append("Complete book text contains HTML markup")
            stats["text_mismatch"] += 1

        # Check if size is reasonable (should be close to total)
        size_diff = abs(full_book_chars - total_epub_chars)
        tolerance = max(500, int(total_epub_chars * 0.05))  # 5% or 500 chars
        if size_diff > tolerance:
            print(
                f"⚠️  Size difference: {size_diff:,} characters ({size_diff / total_epub_chars * 100:.1f}%)"
            )
            stats["completo_size_mismatch"] += 1
            issues.append(f"Complete book text size differs by {size_diff} chars from EPUB total")
        else:
            print("✅ Complete book text is valid and complete")

    if not suppress_errors:
        print("=" * 70)
        if stats["parsed_pretts_diff"] > 0 or stats["text_mismatch"] > 0:
            print("❌ VALIDATION FAILED: Text was modified during conversion!")
            print("   The audio does NOT contain the complete text from the original EPUB.")
        elif stats["missing_mp3"] > 0:
            print("⚠️  VALIDATION INCOMPLETE: Some MP3 files are missing")
        elif stats["completo_size_mismatch"] > 0:
            print("⚠️  VALIDATION WITH WARNINGS: Complete book text size differs from EPUB")
        elif stats["perfect"] == stats["total_chapters"]:
            print("✅ VALIDATION PASSED: All chapters are intact!")
        else:
            print("⚠️  VALIDATION WITH WARNINGS: Check the details above")
        print("=" * 70 + "\n")
