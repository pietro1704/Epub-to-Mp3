# -*- coding: utf-8 -*-
"""CLI resume-state cache: avoid re-statting the output dir on every run."""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import patch

import pytest


@pytest.fixture
def app_with_dirs(tmp_path, monkeypatch):
    output_dir = tmp_path / "out" / "Some_Book"
    output_dir.mkdir(parents=True)
    cache_root = tmp_path / "cache"
    cache_root.mkdir()

    # Drop 11 fake MP3s (90% of 12 expected → reuse threshold met).
    for i in range(11):
        f = output_dir / f"chap_{i}.mp3"
        f.write_bytes(b"\x00" * 64)

    from main import ConverterApplication

    app = ConverterApplication.__new__(ConverterApplication)
    app.cache_root = cache_root

    # Stub the helper that builds the output path so we don't depend on
    # the real config / reader machinery for this unit test.
    monkeypatch.setattr(app, "_resolve_book_output_dir", lambda reader, config: output_dir)

    reader = SimpleNamespace(title="Some Book")
    config = SimpleNamespace()
    args = SimpleNamespace(
        clear_cache=False,
        force=False,
        chapter=None,
        from_chapter_to_chapter=None,
        from_chapter_to_end=None,
    )
    items = [SimpleNamespace(index=str(i)) for i in range(12)]
    return app, reader, config, args, items, output_dir, cache_root


def test_first_call_writes_resume_state(app_with_dirs):
    app, reader, config, args, items, output_dir, cache_root = app_with_dirs
    result = app._detect_reusable_existing_output(reader, items, config, args)
    assert result == output_dir
    state_file = output_dir / "._resume_state.json"
    assert state_file.exists()
    state = json.loads(state_file.read_text())
    assert state["mp3_count"] == 11
    assert state["expected"] == 12


def test_subsequent_call_uses_cached_count(app_with_dirs):
    app, reader, config, args, items, output_dir, cache_root = app_with_dirs
    # First call writes the state file, which itself bumps dir mtime.
    app._detect_reusable_existing_output(reader, items, config, args)
    # Second call rewrites the state with the post-write mtime.
    app._detect_reusable_existing_output(reader, items, config, args)
    # Third call: state mtime now matches dir mtime → cache hit, no scan.
    glob_calls = []
    real_glob = output_dir.glob

    def _spy(*pa, **kw):
        glob_calls.append(pa)
        return real_glob(*pa, **kw)

    with patch.object(type(output_dir), "glob", _spy):
        result = app._detect_reusable_existing_output(reader, items, config, args)
    assert result == output_dir
    assert glob_calls == []  # cache hit short-circuits the scan


def test_cache_invalidates_when_dir_mtime_changes(app_with_dirs):
    app, reader, config, args, items, output_dir, cache_root = app_with_dirs
    app._detect_reusable_existing_output(reader, items, config, args)
    state_file = output_dir / "._resume_state.json"
    state = json.loads(state_file.read_text())
    # Tamper the cached mtime to something far in the past — next call
    # should re-scan and refresh.
    state["dir_mtime"] = 1.0
    state["mp3_count"] = 999
    state_file.write_text(json.dumps(state))

    result = app._detect_reusable_existing_output(reader, items, config, args)
    assert result == output_dir
    refreshed = json.loads(state_file.read_text())
    assert refreshed["mp3_count"] == 11
