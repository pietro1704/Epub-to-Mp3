# -*- coding: utf-8 -*-
"""Hash-based resume state cache invalidation (v0.3.25).

Replaces the previous dir-mtime gate which invalidated on every state
file write — the cache only kicked in on the third call.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest


@pytest.fixture
def app_with_dirs(tmp_path, monkeypatch):
    output_dir = tmp_path / "out" / "Some_Book"
    output_dir.mkdir(parents=True)
    cache_root = tmp_path / "cache"
    cache_root.mkdir()
    for i in range(11):
        (output_dir / f"chap_{i}.mp3").write_bytes(b"\x00" * 64)

    from main import ConverterApplication

    app = ConverterApplication.__new__(ConverterApplication)
    app.cache_root = cache_root
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
    return app, reader, config, args, items, output_dir


def test_second_call_listing_hash_stable(app_with_dirs):
    """Hash-based cache: the listing hash stays identical across calls
    when no MP3s are added or removed, so the cached_count branch fires
    and the state file is not rewritten with new content."""
    app, reader, config, args, items, output_dir = app_with_dirs
    # First call writes the state file with the listing hash.
    app._detect_reusable_existing_output(reader, items, config, args)
    state_file = output_dir / "._resume_state.json"
    state = json.loads(state_file.read_text())
    assert "listing_hash" in state
    assert state["mp3_count"] == 11

    # Second call: listing hasn't changed → cached_count branch hits and
    # returns the same dir without rewriting the state file content.
    result = app._detect_reusable_existing_output(reader, items, config, args)
    assert result == output_dir
    after = json.loads(state_file.read_text())
    assert after["listing_hash"] == state["listing_hash"]
    assert after["mp3_count"] == state["mp3_count"]


def test_invalidates_when_mp3_added(app_with_dirs):
    app, reader, config, args, items, output_dir = app_with_dirs
    app._detect_reusable_existing_output(reader, items, config, args)
    state_file = output_dir / "._resume_state.json"
    initial = json.loads(state_file.read_text())
    # Drop a new MP3 — listing hash must change.
    (output_dir / "new_chap.mp3").write_bytes(b"\x00" * 64)
    items_with_extra = items + [SimpleNamespace(index="extra")]
    app._detect_reusable_existing_output(reader, items_with_extra, config, args)
    refreshed = json.loads(state_file.read_text())
    assert refreshed["listing_hash"] != initial["listing_hash"]
    assert refreshed["mp3_count"] == 12


def test_invalidates_when_mp3_size_changes(app_with_dirs):
    app, reader, config, args, items, output_dir = app_with_dirs
    app._detect_reusable_existing_output(reader, items, config, args)
    state_file = output_dir / "._resume_state.json"
    initial = json.loads(state_file.read_text())
    # Truncate the first MP3 — same name, different size → hash flips.
    target = next(output_dir.glob("*.mp3"))
    target.write_bytes(b"\x00" * 32)  # half the original size
    app._detect_reusable_existing_output(reader, items, config, args)
    refreshed = json.loads(state_file.read_text())
    assert refreshed["listing_hash"] != initial["listing_hash"]
