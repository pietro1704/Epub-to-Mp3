# -*- coding: utf-8 -*-
"""Tests for _ValidationMixin — _categorize_problems, _remove_bad_mp3s."""

from __future__ import annotations

from pathlib import Path

from python_app.src._validation_mixin import _ValidationMixin

# ---------------------------------------------------------------------------
# Minimal concrete subclass
# ---------------------------------------------------------------------------


class _ConcreteValidation(_ValidationMixin):
    def __init__(self, verbose: bool = False):
        self.verbose = verbose


# ---------------------------------------------------------------------------
# _categorize_problems
# ---------------------------------------------------------------------------


class TestCategorizeProblems:
    def test_empty_inputs_return_empty(self):
        v = _ConcreteValidation()
        missing, duration = v._categorize_problems([], [])
        assert missing == []
        assert duration == []

    def test_missing_mp3_only(self):
        v = _ConcreteValidation()
        issues = ["Chapter 1 'Intro': Missing MP3 file"]
        missing, duration = v._categorize_problems(issues, ["1"])
        assert missing == ["1"]
        assert duration == []

    def test_duration_only(self):
        v = _ConcreteValidation()
        issues = ["Chapter 2 'Body': Duration mismatch (expected 90s, got 45s)"]
        missing, duration = v._categorize_problems(issues, ["2"])
        assert missing == []
        assert duration == ["2"]

    def test_mixed_tags_are_not_categorized(self):
        """A chapter with both missing MP3 and another issue is categorised as neither."""
        v = _ConcreteValidation()
        issues = [
            "Chapter 3 'End': Missing MP3 file",
            "Chapter 3 'End': text mismatch detected",
        ]
        missing, duration = v._categorize_problems(issues, ["3"])
        assert "3" not in missing
        assert "3" not in duration

    def test_multiple_chapters_with_different_problems(self):
        v = _ConcreteValidation()
        issues = [
            "Chapter 1 'A': Missing MP3 file",
            "Chapter 2 'B': Duration mismatch (expected 90s, got 60s)",
            "Chapter 3 'C': text mismatch",
        ]
        missing, duration = v._categorize_problems(issues, ["1", "2", "3"])
        assert missing == ["1"]
        assert duration == ["2"]
        # Chapter 3 has "other" tag — not in either list
        assert "3" not in missing
        assert "3" not in duration

    def test_chapter_with_no_matching_issue_is_skipped(self):
        v = _ConcreteValidation()
        issues = ["Chapter 99 'X': Missing MP3 file"]
        missing, duration = v._categorize_problems(issues, ["1"])
        assert missing == []
        assert duration == []

    def test_case_insensitive_missing_mp3(self):
        v = _ConcreteValidation()
        issues = ["Chapter 5 'Z': MISSING MP3 detected"]
        missing, duration = v._categorize_problems(issues, ["5"])
        assert missing == ["5"]

    def test_case_insensitive_duration(self):
        v = _ConcreteValidation()
        issues = ["Chapter 6 'W': DURATION MISMATCH 10s vs 20s"]
        missing, duration = v._categorize_problems(issues, ["6"])
        assert duration == ["6"]

    def test_duration_chapter_with_both_missing_and_duration(self):
        """Two issues for same chapter — one missing mp3, one duration → other wins."""
        v = _ConcreteValidation()
        issues = [
            "Chapter 7 'X': Missing MP3 file",
            "Chapter 7 'X': Duration mismatch",
        ]
        missing, duration = v._categorize_problems(issues, ["7"])
        # Tags = {missing_mp3, duration} — not a pure single-tag set
        assert "7" not in missing
        assert "7" not in duration


# ---------------------------------------------------------------------------
# _remove_bad_mp3s
# ---------------------------------------------------------------------------


class TestRemoveBadMp3s:
    def _make_mp3(self, directory: Path, name: str) -> Path:
        p = directory / name
        p.write_bytes(b"ID3")
        return p

    def test_removes_mp3_named_in_issue(self, tmp_path):
        v = _ConcreteValidation()
        bad_mp3 = self._make_mp3(tmp_path, "bad_chapter.mp3")
        issues = ["MP3 filename 'bad_chapter.mp3' does not match EPUB heading"]
        removed = v._remove_bad_mp3s(tmp_path, issues, [])
        assert "bad_chapter.mp3" in removed
        assert not bad_mp3.exists()

    def test_removes_html_markup_mp3(self, tmp_path):
        v = _ConcreteValidation()
        bad_mp3 = self._make_mp3(tmp_path, "markup<b>.mp3")
        issues = ["MP3 filename contains HTML/markup: markup<b>.mp3"]
        removed = v._remove_bad_mp3s(tmp_path, issues, [])
        assert "markup<b>.mp3" in removed
        assert not bad_mp3.exists()

    def test_removes_mp3_by_decimal_chapter_number(self, tmp_path):
        v = _ConcreteValidation()
        bad_mp3 = self._make_mp3(tmp_path, "4.1 - Chapter Title.mp3")
        issues = []
        removed = v._remove_bad_mp3s(tmp_path, issues, ["4.1"])
        assert "4.1 - Chapter Title.mp3" in removed
        assert not bad_mp3.exists()

    def test_removes_mp3_by_zero_padded_chapter_number(self, tmp_path):
        v = _ConcreteValidation()
        bad_mp3 = self._make_mp3(tmp_path, "004 - Chapter.mp3")
        issues = []
        removed = v._remove_bad_mp3s(tmp_path, issues, ["4"])
        assert "004 - Chapter.mp3" in removed
        assert not bad_mp3.exists()

    def test_does_not_remove_unrelated_mp3(self, tmp_path):
        v = _ConcreteValidation()
        good_mp3 = self._make_mp3(tmp_path, "2 - Good Chapter.mp3")
        issues = []
        removed = v._remove_bad_mp3s(tmp_path, issues, ["5"])
        assert "2 - Good Chapter.mp3" not in removed
        assert good_mp3.exists()

    def test_returns_empty_list_when_nothing_to_remove(self, tmp_path):
        v = _ConcreteValidation()
        self._make_mp3(tmp_path, "1 - Keep Me.mp3")
        removed = v._remove_bad_mp3s(tmp_path, [], [])
        assert removed == []

    def test_returns_empty_list_when_output_dir_missing(self, tmp_path):
        v = _ConcreteValidation()
        nonexistent = tmp_path / "does_not_exist"
        # Should not raise even if directory doesn't exist
        removed = v._remove_bad_mp3s(nonexistent, [], [])
        assert removed == []

    def test_removes_multiple_bad_mp3s_in_one_call(self, tmp_path):
        v = _ConcreteValidation()
        mp3_a = self._make_mp3(tmp_path, "1.0 - Intro.mp3")
        mp3_b = self._make_mp3(tmp_path, "2.0 - Body.mp3")
        removed = v._remove_bad_mp3s(tmp_path, [], ["1.0", "2.0"])
        assert not mp3_a.exists()
        assert not mp3_b.exists()
        assert len(removed) == 2

    def test_mp3_already_deleted_not_in_removed(self, tmp_path):
        v = _ConcreteValidation()
        issues = ["MP3 filename 'ghost.mp3' does not match EPUB heading"]
        removed = v._remove_bad_mp3s(tmp_path, issues, [])
        # File never existed — should not appear in removed
        assert "ghost.mp3" not in removed
