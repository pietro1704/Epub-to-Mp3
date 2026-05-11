"""Tests for the Android Chaquopy bridge entrypoints."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from python_app.src import android_entrypoints

FIXTURE_EPUB = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"


def test_bootstrap_returns_python_version() -> None:
    result = android_entrypoints.bootstrap()
    assert isinstance(result, str)
    assert sys.version.split()[0] in result


@pytest.mark.skipif(not FIXTURE_EPUB.exists(), reason="fixture EPUB missing")
def test_parse_epub_to_dict_shape() -> None:
    payload = android_entrypoints.parse_epub_to_dict(str(FIXTURE_EPUB))
    # Keys mirror flutter_app/lib/models/ebook_fulltext.dart (camelCase)
    assert set(payload.keys()) == {"jobId", "bookTitle", "bookAuthor", "chapters"}
    assert isinstance(payload["chapters"], list)
    assert len(payload["chapters"]) > 0
    for ch in payload["chapters"]:
        assert set(ch.keys()) >= {"index", "name", "text", "charCount", "level"}
        assert isinstance(ch["text"], str)
        assert isinstance(ch["charCount"], int)
        assert ch["charCount"] == len(ch["text"])


@pytest.mark.skipif(not FIXTURE_EPUB.exists(), reason="fixture EPUB missing")
def test_parse_epub_to_json_is_valid_json() -> None:
    raw = android_entrypoints.parse_epub_to_json(str(FIXTURE_EPUB))
    assert isinstance(raw, str)
    decoded = json.loads(raw)
    assert decoded["chapters"], "expected at least one chapter"
    assert "bookTitle" in decoded


def test_parse_epub_to_dict_missing_file_raises() -> None:
    with pytest.raises((RuntimeError, FileNotFoundError, OSError)):
        android_entrypoints.parse_epub_to_dict("/nonexistent/path/xyz.epub")
