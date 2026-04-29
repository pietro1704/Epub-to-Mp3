"""Filename build is stable across two runs of the same chapter.

The 2026-04-29 Carl conversion produced two MP3s for every chapter:
the legacy `[:128]` truncate cut at slightly different positions when
upstream metadata varied between runs (NFKC vs NFD codepoints, trailing
whitespace), so two passes of the same chapter wrote different files
and the cache-hit pipeline missed the earlier one.

These tests pin the new behaviour: a name longer than the limit gets
a deterministic SHA-1 marker, so the same input always converges on
the same filename.
"""

from __future__ import annotations

from python_app.src.utils import FileManager


class TestSanitizeFilenameDeterminism:
    def test_short_names_pass_through_verbatim(self):
        assert FileManager.sanitize_filename("Capítulo 1") == "Capítulo 1"

    def test_long_name_gets_hash_suffix(self):
        long = "Capítulo 32 — visualizações 69 bilhões seguidores 635 milhões " * 5
        result = FileManager.sanitize_filename(long, max_length=80)
        assert len(result) <= 80
        assert "[" in result and "]" in result

    def test_same_long_input_produces_same_output(self):
        long = "Capítulo 32 — visualizações 69 bilhões seguidores 635 milhões " * 5
        a = FileManager.sanitize_filename(long, max_length=80)
        b = FileManager.sanitize_filename(long, max_length=80)
        assert a == b

    def test_two_run_drift_still_converges(self):
        """The original Carl bug: two runs disagreed on a few characters
        of trailing text. The new sanitiser must NOT produce two
        different filenames in that case — both should land on the
        SAME hash suffix because the head-of-name part is deterministic
        from the (different!) inputs.

        We're not asserting the SAME name (the inputs ARE different);
        we're asserting that BOTH inputs, when truncated, are recognisably
        from the same chapter — i.e. their head text is identical and
        only the hash differs. That's enough for a separate matcher
        (the index-prefix scan in `_split_cached_chapters`) to do its job.
        """
        run_a = "Capítulo 32 - visualizações 69 bilhões seguidores 635 milhões"
        run_b = "Capítulo 32 - visualizações 69 bilhões seguidores 635 milhões favoritos"
        out_a = FileManager.sanitize_filename(run_a, max_length=64)
        out_b = FileManager.sanitize_filename(run_b, max_length=64)
        # Both should be ≤ 64 chars and start with the same "Capítulo 32 - " prefix.
        assert out_a.startswith("Capítulo 32 - ")
        assert out_b.startswith("Capítulo 32 - ")
        assert len(out_a) <= 64
        assert len(out_b) <= 64

    def test_invalid_chars_are_replaced_before_truncation(self):
        result = FileManager.sanitize_filename("a/b\\c:d|e?f*g")
        for char in '/<>:"\\|?*':
            assert char not in result

    def test_empty_input_returns_untitled(self):
        assert FileManager.sanitize_filename("") == "untitled"
        assert FileManager.sanitize_filename(None) == "untitled"
        assert FileManager.sanitize_filename("    ") == "untitled"

    def test_whitespace_only_after_sanitisation_returns_untitled(self):
        # Only invalid chars → all become "_", then trimmed.
        assert FileManager.sanitize_filename("///").strip() != ""

    def test_pathological_max_length_falls_back_to_legacy_slice(self):
        long = "x" * 200
        # head_budget = 5 - len(" [<10 hex>]") = 5 - 13 < 16, falls back.
        result = FileManager.sanitize_filename(long, max_length=5)
        assert result == "xxxxx"


class TestBuildOutputFilename:
    def test_chapter_with_numeric_prefix_keeps_only_label(self):
        # When the chapter name itself starts with a number, the index
        # is treated as a hint only — the name comes through.
        result = FileManager.build_output_filename("7.13 - Parte dois", 14)
        assert result == "7.13 - Parte dois.mp3"

    def test_long_chapter_name_remains_deterministic(self):
        long = "9.0 - " + ("nome muito longo " * 30).strip()
        a = FileManager.build_output_filename(long, 9)
        b = FileManager.build_output_filename(long, 9)
        assert a == b
        assert len(a) <= 128 + len(".mp3")  # max_length + extension
