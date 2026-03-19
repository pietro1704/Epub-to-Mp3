#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TDD Tests: Verify there is no content duplication in conversion.
Test-Driven Development - these tests define the expected behavior.
"""

import sys
from pathlib import Path
from typing import List, Set

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from src.ebook_reader import EbookReader


def test_no_duplicate_chapters_in_structure():
    """
    TDD RED: Test that there are no duplicate chapters in the structure.

    Expected behavior:
    - Each chapter must appear ONLY ONCE
    - No text should be duplicated across chapters
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    assert epub_path.exists(), f"Test EPUB not found: {epub_path}"

    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    # Verify we have exactly 2 chapters
    assert len(chapters) == 2, f"Expected 2 chapters, got {len(chapters)}"

    # Verify chapter names are unique
    chapter_names = [ch.name for ch in chapters]
    assert len(chapter_names) == len(
        set(chapter_names)
    ), f"Duplicate chapter names: {chapter_names}"

    # Verify texts are NOT identical
    chapter_texts = [ch.text for ch in chapters]
    for i, text1 in enumerate(chapter_texts):
        for j, text2 in enumerate(chapter_texts):
            if i != j:
                assert text1 != text2, f"Chapters {i} and {j} have identical text (duplication!)"


def test_no_duplicate_content_within_chapter():
    """
    TDD RED: Test that there are no repeated sentences within the same chapter.

    Expected behavior:
    - No sentence with >20 characters should appear twice in the same chapter
    - Exception: footnotes may have small context repetitions
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    for idx, chapter in enumerate(chapters):
        text = chapter.text

        # Split into sentences (simple approximation)
        sentences = [s.strip() for s in text.split(".") if len(s.strip()) > 20]

        # Check for duplicates
        seen: Set[str] = set()
        duplicates: List[str] = []

        for sentence in sentences:
            # Normalize (remove extra spaces, lowercase)
            normalized = " ".join(sentence.lower().split())

            if normalized in seen:
                duplicates.append(sentence[:80])
            seen.add(normalized)

        # Allow AT MOST 1 duplicate (footnote context)
        assert len(duplicates) <= 1, (
            f"Chapter {idx} ({chapter.name}) has {len(duplicates)} duplicate sentences:\n"
            + "\n".join(f"  - {d}" for d in duplicates[:3])
        )


def test_chapter_text_length_reasonable():
    """
    TDD RED: Test that chapter text lengths are within expected bounds.

    Expected behavior:
    - Chapter 1: ~600-700 characters (original has 618)
    - Chapter 2: ~400-500 characters (original has 419)
    - If DOUBLE the expected size, it may indicate duplication!
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    # Expected bounds (with 50% margin)
    expected_lengths = [
        (600, 900, "Chapter 1"),  # min, max, name
        (400, 600, "Chapter 2"),
    ]

    for idx, (min_len, max_len, expected_name) in enumerate(expected_lengths):
        if idx >= len(chapters):
            break

        chapter = chapters[idx]
        actual_len = len(chapter.text)

        assert min_len <= actual_len <= max_len, (
            f"Chapter {idx} ({chapter.name}) has {actual_len} chars, "
            + f"expected between {min_len}-{max_len}. "
            + "May indicate duplication if much larger, or missing content if much smaller!"
        )


def test_footnote_markers_not_duplicated():
    """
    TDD RED: Test that footnote markers are not duplicated.

    Expected behavior:
    - Markers like [1], [2], etc. must appear ONLY ONCE
    - Each footnote must be processed only once
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    import re

    for idx, chapter in enumerate(chapters):
        text = chapter.text

        # Find all footnote markers [N]
        markers = re.findall(r"\[(\d+)\]", text)

        if not markers:
            continue  # Chapter has no footnotes

        # Check for duplicates
        marker_counts = {}
        for marker in markers:
            marker_counts[marker] = marker_counts.get(marker, 0) + 1

        duplicates = {m: count for m, count in marker_counts.items() if count > 1}

        assert not duplicates, (
            f"Chapter {idx} ({chapter.name}) has duplicate footnote markers: {duplicates}\n"
            + "This indicates footnotes may be processed multiple times!"
        )


def test_no_double_chapter_titles():
    """
    TDD RED: Test that chapter titles do not appear twice in the text.

    Expected behavior:
    - The chapter title must appear ONLY ONCE at the beginning
    - It must not be repeated in the middle or end of the text
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    for idx, chapter in enumerate(chapters):
        title = chapter.name
        text = chapter.text

        # Count how many times the title appears in the text
        title_count = text.count(title)

        # Title must appear AT MOST once (at the start)
        # If it appears 2+ times, there is content duplication!
        assert title_count <= 1, (
            f"Chapter {idx}: title '{title}' appears {title_count} times in text!\n"
            + "This indicates content duplication.\n"
            + f"Text: {text[:200]}..."
        )


if __name__ == "__main__":
    import pytest

    print("=" * 70)
    print("TDD TESTS: Content Duplication Check")
    print("=" * 70)
    print("\nThese tests define the expected behavior (RED phase).")
    print("If they fail, the code needs to be fixed (GREEN phase).\n")

    # Run tests
    exit_code = pytest.main([__file__, "-v", "--tb=short"])

    if exit_code == 0:
        print("\n" + "=" * 70)
        print("✅ ALL TESTS PASSED!")
        print("=" * 70)
    else:
        print("\n" + "=" * 70)
        print("❌ SOME TESTS FAILED - Code needs to be fixed")
        print("=" * 70)

    sys.exit(exit_code)
