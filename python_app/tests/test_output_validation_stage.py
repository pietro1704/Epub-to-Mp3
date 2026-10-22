"""Validation-stage extraction preserves final acceptance and retry cancellation."""

import asyncio
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest
from src import _validation_mixin as validation

import validate_conversion


class _Host(validation._ValidationMixin):
    verbose = False
    _auto_fix_guard = False

    def __init__(self, root):
        self._current_book_path = root / "book.epub"
        self._current_book_path.write_bytes(b"fixture")
        self._active_config = SimpleNamespace(
            auto_validate_output=True, auto_fix_output=False, extra={}, cache_dir=root,
        )
        self._last_output_dir = root

    def _parse_chapter_whitelist(self, config):
        return []


@pytest.mark.asyncio
@pytest.mark.parametrize("issues, expected", [([], True), (["Chapter 1: Missing MP3 file"], False)])
async def test_final_validation_keeps_path_identity_and_acceptance(tmp_path, monkeypatch, issues, expected):
    host = _Host(tmp_path)
    validator = Mock(return_value=({}, issues))
    monkeypatch.setattr(validate_conversion, "validate_book", validator)
    assert await host._auto_validate_output(tmp_path) is expected
    assert host._final_validation_passed is expected
    validator.assert_called_once_with(host._current_book_path, tmp_path, cache_dir=tmp_path)


@pytest.mark.asyncio
async def test_final_probe_failure_returns_false_without_escaping(tmp_path, monkeypatch):
    host = _Host(tmp_path)
    monkeypatch.setattr(validate_conversion, "validate_book", Mock(side_effect=OSError("probe failed")))
    assert await host._auto_validate_output(tmp_path) is False
    assert host._final_validation_passed is False


@pytest.mark.asyncio
async def test_retry_cancellation_resets_guard_and_propagates(tmp_path):
    host = _Host(tmp_path)
    host._active_config.auto_fix_output = True
    host._auto_validate_and_retry_async = AsyncMock(side_effect=asyncio.CancelledError)
    with pytest.raises(asyncio.CancelledError):
        await host._auto_validate_output(tmp_path)
    assert host._auto_fix_guard is False


def test_dedup_keeps_distinct_decimal_chapter_identities(tmp_path, monkeypatch):
    first = tmp_path / "7.1 - first.mp3"
    second = tmp_path / "7.10 - second.mp3"
    first.write_bytes(b"first")
    second.write_bytes(b"second")
    probe = Mock(side_effect=AssertionError("distinct labels do not need probing"))
    monkeypatch.setattr("subprocess.run", probe)
    assert _Host(tmp_path)._dedup_chapter_outputs(tmp_path) == 0
    assert first.exists() and second.exists()
    probe.assert_not_called()


def test_bad_output_removal_cancellation_propagates_without_touching_file(tmp_path, monkeypatch):
    output = tmp_path / "1 - chapter.mp3"
    output.write_bytes(b"audio")
    monkeypatch.setattr(Path, "unlink", Mock(side_effect=KeyboardInterrupt))
    with pytest.raises(KeyboardInterrupt):
        _Host(tmp_path)._remove_bad_mp3s(tmp_path, [], ["1"])
    assert output.read_bytes() == b"audio"
