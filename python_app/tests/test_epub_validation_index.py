"""Deep validation index/report extraction keeps content and result identities."""

from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from src import ebook_reader
from src.deep_validation_report import ChapterComparison, ValidationReport
from src.deep_validator import ChapterComparison as PublicComparison
from src.deep_validator import DeepValidator
from src.deep_validator import ValidationReport as PublicReport


def test_epub_index_matches_content_when_converter_relabels_chapter(tmp_path, monkeypatch):
    content = " ".join(f"word{index}" for index in range(100))
    chapters = [SimpleNamespace(index="7.13", text=content)]
    reader = SimpleNamespace(get_chapters=lambda: chapters)
    monkeypatch.setattr(ebook_reader, "EbookReader", Mock(return_value=reader))
    validator = DeepValidator("fixture.epub", str(tmp_path))
    assert validator.load_epub_chapters()
    assert validator._chapter_list is chapters
    indexed = validator.epub_chapters[validator._content_fingerprint(content)]
    assert indexed == content
    assert validator._find_epub_match("Added section heading " + content) is indexed
    assert validator._find_epub_match("entirely unrelated text") is None


def test_epub_index_read_failure_remains_best_effort(tmp_path, monkeypatch):
    monkeypatch.setattr(ebook_reader, "EbookReader", Mock(side_effect=OSError("read failed")))
    validator = DeepValidator("fixture.epub", str(tmp_path))
    assert not validator.load_epub_chapters()
    assert validator.epub_chapters == {}


def test_epub_index_cancellation_propagates(tmp_path, monkeypatch):
    monkeypatch.setattr(ebook_reader, "EbookReader", Mock(side_effect=KeyboardInterrupt))
    with pytest.raises(KeyboardInterrupt):
        DeepValidator("fixture.epub", str(tmp_path)).load_epub_chapters()


def test_public_report_models_share_identity_and_keep_correction_lists_independent():
    assert PublicComparison is ChapterComparison
    assert PublicReport is ValidationReport
    values = dict(
        total_chapters=0, valid_chapters=0, duplicates_found=0, char_mismatches=0,
        content_mismatches=0, comparisons=[], duplicate_files=[], success=True,
    )
    first = PublicReport(**values)
    second = PublicReport(**values)
    first.corrections_made.append("first only")
    assert second.corrections_made == []
