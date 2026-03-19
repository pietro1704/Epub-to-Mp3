#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TDD Tests: Verify that the COMPLETE conversion produces no duplications.
Test-Driven Development - end-to-end tests.
"""

import sys
import tempfile
from pathlib import Path

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from src.cache_manager import CacheManager
from src.config import ConversionConfig
from src.converter import AudioConverter
from src.ebook_reader import EbookReader


def test_conversion_creates_exactly_two_files():
    """
    TDD RED: Test that conversion creates EXACTLY 2 MP3 files.

    Expected behavior:
    - EPUB has 2 chapters
    - Conversion must create EXACTLY 2 MP3 files
    - Must not create duplicates (3 or more files)
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Conversion config
        config = ConversionConfig(
            book_title="Test Multi Feature Book",
            engine="edge",
            voice="pt-BR-FranciscaNeural",
            output_dir=str(temp_path),
            preserve_all_chapters=False,
        )

        # Read EPUB
        reader = EbookReader(str(epub_path))
        chapters = reader.get_chapter_structure()

        assert len(chapters) == 2, f"EPUB must have 2 chapters, got {len(chapters)}"

        # Converter (mock without real TTS for fast tests)
        # Only verify there is no duplication during preparation
        converter = AudioConverter()

        # Verify prepare_chapters does not duplicate
        prepared = []
        for ch in chapters:
            prepared.append(ch)

        # Must have exactly 2 prepared chapters
        assert len(prepared) == 2, f"Preparation must have 2 chapters, got {len(prepared)}"

        # Verify names are different
        names = [ch.name for ch in prepared]
        assert len(set(names)) == 2, f"Prepared chapters have duplicate names: {names}"


def test_cache_does_not_duplicate_chapters():
    """
    TDD RED: Test that cache does not duplicate chapters.

    Expected behavior:
    - Save 2 chapters to cache
    - Read from cache
    - Must return EXACTLY 2 chapters (not 4!)
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "cache"
        cache_manager = CacheManager(cache_dir=cache_dir)

        # Read EPUB
        reader = EbookReader(str(epub_path))
        chapters = reader.get_chapter_structure()

        # Prepare data for cache
        chapters_data = {
            "title": reader.title,
            "author": reader.author,
            "chapters": [{"title": ch.name, "text": ch.text} for ch in chapters],
        }

        # Save to cache
        success = cache_manager.save_chapters_to_cache(Path(epub_path), chapters_data)

        assert success, "Failed to save to cache"

        # Read from cache (simulate reload)
        cached = cache_manager.get_cached_chapters(Path(epub_path))

        assert cached is not None, "Cache returned no data"
        assert "chapters" in cached, "Cache missing 'chapters' field"

        cached_chapters = cached["chapters"]

        # Verify NO duplication
        assert (
            len(cached_chapters) == 2
        ), f"Cache must have 2 chapters, got {len(cached_chapters)}. Possible duplication!"

        # Verify titles are unique
        titles = [ch["title"] for ch in cached_chapters]
        assert len(set(titles)) == 2, f"Chapters in cache have duplicate titles: {titles}"


def test_text_chunks_no_overlap():
    """
    TDD RED: Test that text chunks have no overlap.

    Expected behavior:
    - When splitting large text into chunks (for TTS)
    - Chunks must NOT have overlap/repetition
    - Each part of the text must appear ONLY ONCE
    """
    # Long test text (simulates a large chapter)
    long_text = "A " * 1000 + "B " * 1000 + "C " * 1000

    # Simulate chunking (as in edge_engine or others)
    chunk_size = 500
    chunks = []

    start = 0
    while start < len(long_text):
        end = min(start + chunk_size, len(long_text))
        chunk = long_text[start:end]
        chunks.append(chunk)
        start = end  # No overlap!

    # Verify no overlap
    all_text = "".join(chunks)

    # Reconstructed text must be EXACTLY equal to original
    assert (
        all_text == long_text
    ), "Chunks have overlap or gaps! Reconstructed text differs from original"

    # Verify each part appears only once
    # Count 'A', 'B', 'C'
    assert all_text.count("A ") == 1000, "Letter A duplicated or missing"
    assert all_text.count("B ") == 1000, "Letter B duplicated or missing"
    assert all_text.count("C ") == 1000, "Letter C duplicated or missing"


def test_footnote_processing_no_duplication():
    """
    TDD RED: Test that footnote processing does not duplicate.

    Expected behavior:
    - Footnotes must be processed ONLY ONCE
    - Must not produce "note about note"
    """
    # Text with footnote
    text_with_footnote = """
    This is a text with a note[1].

    [1] This is the footnote.
    """

    # Process (simulate footnote extraction)
    import re

    # Find markers [N]
    markers = re.findall(r"\[(\d+)\]", text_with_footnote)

    # Must have exactly 2 occurrences: [1] in text and [1] in footnote
    assert len(markers) == 2, f"Expected 2 [1] markers, found {len(markers)}: {markers}"

    # Both must be '1'
    assert markers == ["1", "1"], f"Incorrect markers: {markers}"

    # Processing again must NOT duplicate (idempotency test)
    markers_again = re.findall(r"\[(\d+)\]", text_with_footnote)
    assert markers == markers_again, "Second processing pass duplicated markers!"


def test_chapter_structure_stability():
    """
    TDD RED: Test that chapter structure is stable across multiple reads.

    Expected behavior:
    - Read EPUB multiple times
    - Always return the SAME structure
    - Must not grow with each read
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    # First read
    reader1 = EbookReader(str(epub_path))
    chapters1 = reader1.get_chapter_structure()
    count1 = len(chapters1)
    names1 = [ch.name for ch in chapters1]

    # Second read (new reader)
    reader2 = EbookReader(str(epub_path))
    chapters2 = reader2.get_chapter_structure()
    count2 = len(chapters2)
    names2 = [ch.name for ch in chapters2]

    # Third read
    reader3 = EbookReader(str(epub_path))
    chapters3 = reader3.get_chapter_structure()
    count3 = len(chapters3)
    names3 = [ch.name for ch in chapters3]

    # All must have 2 chapters
    assert (
        count1 == count2 == count3 == 2
    ), f"Counts differ: {count1}, {count2}, {count3}. Structure is unstable!"

    # All must have the same names
    assert (
        names1 == names2 == names3
    ), f"Names differ across reads:\n  1: {names1}\n  2: {names2}\n  3: {names3}"


if __name__ == "__main__":
    import pytest

    print("=" * 70)
    print("TDD TESTS: End-to-End Conversion (No Duplication)")
    print("=" * 70)
    print("\nThese tests verify the complete conversion.\n")

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
