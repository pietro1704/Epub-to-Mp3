# -*- coding: utf-8 -*-
"""v0.3.28: per-chapter TXT writes parallelized + metadata.json drops
indent=2."""

from __future__ import annotations

import json

from src.cache_manager import CacheManager


def test_save_chapters_writes_metadata_without_indent(tmp_path):
    cache_root = tmp_path / "cache"
    cache_root.mkdir()
    cm = CacheManager(cache_dir=cache_root)
    fake_epub = tmp_path / "book.epub"
    fake_epub.write_bytes(b"PK\x03\x04")
    chapters = [{"title": f"C{i}", "text": f"Body {i}"} for i in range(5)]
    ok = cm.save_chapters_to_cache(fake_epub, {"title": "X", "author": "Y", "chapters": chapters})
    assert ok is True
    metadata_path = cm._get_cache_path(fake_epub) / "metadata.json"
    raw = metadata_path.read_text(encoding="utf-8")
    # No indent → single line.
    assert "\n" not in raw.strip()
    parsed = json.loads(raw)
    assert parsed["chapters_count"] == 5


def test_save_chapters_parallel_writes_all_files(tmp_path):
    cache_root = tmp_path / "cache"
    cache_root.mkdir()
    cm = CacheManager(cache_dir=cache_root)
    fake_epub = tmp_path / "big.epub"
    fake_epub.write_bytes(b"PK\x03\x04")
    chapters = [{"title": f"Ch {i}", "text": f"text {i}"} for i in range(20)]
    ok = cm.save_chapters_to_cache(fake_epub, {"title": "Big", "author": "A", "chapters": chapters})
    assert ok is True
    txt_dir = cm._get_cache_path(fake_epub) / "txt"
    files = sorted(txt_dir.glob("*.txt"))
    assert len(files) == 20
    # Verify content survives the parallel write.
    contents = {p.read_text(encoding="utf-8") for p in files}
    assert contents == {f"text {i}" for i in range(20)}


def test_save_chapters_serial_path_for_few_entries(tmp_path):
    """The serial path triggers when len <= 4. Just verify it still works."""
    cache_root = tmp_path / "cache"
    cache_root.mkdir()
    cm = CacheManager(cache_dir=cache_root)
    fake_epub = tmp_path / "small.epub"
    fake_epub.write_bytes(b"PK\x03\x04")
    chapters = [{"title": "Single", "text": "only one"}]
    ok = cm.save_chapters_to_cache(fake_epub, {"title": "S", "author": "A", "chapters": chapters})
    assert ok is True
    txt_dir = cm._get_cache_path(fake_epub) / "txt"
    files = list(txt_dir.glob("*.txt"))
    assert len(files) == 1
    assert files[0].read_text(encoding="utf-8") == "only one"


def test_save_chapters_skips_invalid_entries(tmp_path):
    cache_root = tmp_path / "cache"
    cache_root.mkdir()
    cm = CacheManager(cache_dir=cache_root)
    fake_epub = tmp_path / "mixed.epub"
    fake_epub.write_bytes(b"PK\x03\x04")
    chapters = [{"title": "ok", "text": "fine"}, "garbage", None, {"title": "ok2", "text": "fine2"}]
    ok = cm.save_chapters_to_cache(fake_epub, {"title": "M", "author": "A", "chapters": chapters})
    assert ok is True
    txt_dir = cm._get_cache_path(fake_epub) / "txt"
    files = list(txt_dir.glob("*.txt"))
    assert len(files) == 2
